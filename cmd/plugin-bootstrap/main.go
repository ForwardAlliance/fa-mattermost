package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	mattermostBinary = "/mattermost/bin/mattermost"
	mmctlBinary      = "/mattermost/bin/mmctl"
	bundlesDirectory = "/mattermost/forward-plugin-bundles"
	memberRole       = "team_user"
)

// Channels are created only by admins and by the volunteers app through the
// admin token. Mattermost has no config setting for this; it is governed by
// these team_user permissions, which the default scheme grants.
var revokedMemberPermissions = []string{
	"create_public_channel",
	"create_private_channel",
}

type pluginListEntry struct {
	Active   []pluginInfo `json:"active"`
	Inactive []pluginInfo `json:"inactive"`
}

type pluginInfo struct {
	ID string `json:"id"`
}

type pluginStatus struct {
	active bool
}

func main() {
	serverCmd := exec.Command(mattermostBinary)
	serverCmd.Stdout = os.Stdout
	serverCmd.Stderr = os.Stderr
	serverCmd.Stdin = os.Stdin

	if err := serverCmd.Start(); err != nil {
		log.Fatalf("failed to start mattermost: %v", err)
	}

	forwardSignals(serverCmd)

	go bootstrap()

	if err := serverCmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}

		log.Fatalf("mattermost exited with error: %v", err)
	}
}

func forwardSignals(serverCmd *exec.Cmd) {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		for sig := range signals {
			if serverCmd.Process == nil {
				return
			}

			if err := serverCmd.Process.Signal(sig); err != nil {
				log.Printf("failed to forward signal %s to mattermost: %v", sig, err)
			}
		}
	}()
}

func bootstrap() {
	statuses, err := waitForPluginList()
	if err != nil {
		log.Printf("bootstrap could not reach Mattermost local API: %v", err)
		return
	}

	bootstrapPlugins(statuses)
	enforceMemberPermissions()
}

// Role permissions live in the database rather than in config, so a change made
// in the System Console is invisible to the repo and can drift between
// environments. Reapplying on every boot keeps the policy version controlled;
// a console edit to these permissions is deliberately reverted on restart.
func enforceMemberPermissions() {
	args := append([]string{"permissions", "remove", memberRole}, revokedMemberPermissions...)
	args = append(args, "--local")

	if err := runMMCTL(args...); err != nil {
		log.Printf("ERROR bootstrap failed to revoke %v from %s; members can still create channels: %v", revokedMemberPermissions, memberRole, err)
		return
	}

	log.Printf("bootstrap revoked %v from %s", revokedMemberPermissions, memberRole)
}

func bootstrapPlugins(statuses map[string]pluginStatus) {
	bundles, err := filepath.Glob(filepath.Join(bundlesDirectory, "*.tar.gz"))
	if err != nil {
		log.Printf("plugin bootstrap failed to enumerate bundles: %v", err)
		return
	}

	if len(bundles) == 0 {
		log.Printf("plugin bootstrap found no bundles in %s", bundlesDirectory)
		return
	}

	for _, bundlePath := range bundles {
		pluginID := strings.TrimSuffix(filepath.Base(bundlePath), ".tar.gz")

		if _, exists := statuses[pluginID]; !exists {
			if err := runMMCTL("plugin", "add", bundlePath, "--local"); err != nil {
				log.Printf("plugin bootstrap failed to install %s from %s: %v", pluginID, bundlePath, err)
				continue
			}

			statuses, err = listPlugins()
			if err != nil {
				log.Printf("plugin bootstrap failed to refresh plugin list after installing %s: %v", pluginID, err)
				continue
			}
		}

		status, exists := statuses[pluginID]
		if exists && status.active {
			continue
		}

		if err := runMMCTL("plugin", "enable", pluginID, "--local"); err != nil {
			log.Printf("plugin bootstrap failed to enable %s: %v", pluginID, err)
			continue
		}

		log.Printf("plugin bootstrap enabled %s", pluginID)
	}
}

func waitForPluginList() (map[string]pluginStatus, error) {
	var lastErr error

	for range 60 {
		statuses, err := listPlugins()
		if err == nil {
			return statuses, nil
		}

		lastErr = err
		time.Sleep(time.Second)
	}

	return nil, lastErr
}

func listPlugins() (map[string]pluginStatus, error) {
	output, err := exec.Command(mmctlBinary, "plugin", "list", "--local", "--json", "--suppress-warnings").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("mmctl plugin list failed: %w (%s)", err, strings.TrimSpace(string(output)))
	}

	jsonPayload := extractJSONArray(string(output))
	if jsonPayload == "" {
		return nil, fmt.Errorf("mmctl plugin list returned no JSON: %s", strings.TrimSpace(string(output)))
	}

	var entries []pluginListEntry
	if err := json.Unmarshal([]byte(jsonPayload), &entries); err != nil {
		return nil, fmt.Errorf("failed to parse mmctl plugin list JSON: %w", err)
	}

	statuses := make(map[string]pluginStatus)
	for _, entry := range entries {
		for _, plugin := range entry.Active {
			statuses[plugin.ID] = pluginStatus{active: true}
		}

		for _, plugin := range entry.Inactive {
			statuses[plugin.ID] = pluginStatus{active: false}
		}
	}

	return statuses, nil
}

func extractJSONArray(output string) string {
	start := strings.Index(output, "[")
	end := strings.LastIndex(output, "]")
	if start == -1 || end == -1 || end < start {
		return ""
	}

	return output[start : end+1]
}

func runMMCTL(args ...string) error {
	cmd := exec.Command(mmctlBinary, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w (%s)", err, strings.TrimSpace(string(output)))
	}

	return nil
}
