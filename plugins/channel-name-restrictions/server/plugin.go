package main

import (
	"strings"
	"sync"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

const (
	defaultRejectionMessage = "Only admins can create channels whose name starts with a restricted prefix."
)

type configuration struct {
	RestrictedPrefixes string
	RejectionMessage   string
	restrictedPrefixes []string
}

type Plugin struct {
	plugin.MattermostPlugin

	configurationLock sync.RWMutex
	configuration     *configuration
}

func (p *Plugin) OnActivate() error {
	return p.OnConfigurationChange()
}

func (p *Plugin) OnConfigurationChange() error {
	nextConfig := &configuration{}

	if err := p.API.LoadPluginConfiguration(nextConfig); err != nil {
		return err
	}

	nextConfig.restrictedPrefixes = parseRestrictedPrefixes(nextConfig.RestrictedPrefixes)

	p.configurationLock.Lock()
	p.configuration = nextConfig
	p.configurationLock.Unlock()

	return nil
}

// Mattermost only exposes ChannelHasBeenCreated, so unauthorized channels must
// be rolled back immediately after creation instead of being rejected up front.
func (p *Plugin) ChannelHasBeenCreated(_ *plugin.Context, channel *model.Channel) {
	if channel == nil || channel.DeleteAt != 0 || channel.CreatorId == "" {
		return
	}

	if channel.Type != model.ChannelTypeOpen && channel.Type != model.ChannelTypePrivate {
		return
	}

	config := p.getConfiguration()
	matchedPrefix := config.matchingPrefix(channel.DisplayName, channel.Name)
	if matchedPrefix == "" {
		return
	}

	if p.isAdmin(channel.CreatorId, channel.TeamId) {
		return
	}

	p.notifyBlockedCreator(channel.CreatorId, channel.Id, matchedPrefix, config.notificationMessage(matchedPrefix))

	if appErr := p.API.DeleteChannel(channel.Id); appErr != nil {
		p.API.LogError(
			"channel-name-restrictions failed to delete restricted channel",
			"channel_id", channel.Id,
			"channel_name", channel.Name,
			"channel_display_name", channel.DisplayName,
			"creator_id", channel.CreatorId,
			"matched_prefix", matchedPrefix,
			"error", appErr.Error(),
		)
		return
	}

	p.API.LogInfo(
		"channel-name-restrictions deleted unauthorized restricted channel",
		"channel_id", channel.Id,
		"channel_name", channel.Name,
		"channel_display_name", channel.DisplayName,
		"creator_id", channel.CreatorId,
		"matched_prefix", matchedPrefix,
	)
}

func (p *Plugin) getConfiguration() configuration {
	p.configurationLock.RLock()
	defer p.configurationLock.RUnlock()

	if p.configuration == nil {
		return configuration{}
	}

	return *p.configuration
}

func (p *Plugin) isAdmin(userID, teamID string) bool {
	if p.API.HasPermissionTo(userID, model.PermissionManageSystem) {
		return true
	}

	if teamID != "" && p.API.HasPermissionToTeam(userID, teamID, model.PermissionManageTeam) {
		return true
	}

	return false
}

func (p *Plugin) notifyBlockedCreator(userID, channelID, matchedPrefix, rejectionMessage string) {
	post := &model.Post{
		ChannelId: channelID,
		Message:   rejectionMessage,
	}

	if p.API.SendEphemeralPost(userID, post) == nil {
		p.API.LogWarn(
			"channel-name-restrictions failed to send ephemeral rejection notice",
			"user_id", userID,
			"channel_id", channelID,
			"matched_prefix", matchedPrefix,
		)
	}
}

func (c configuration) matchingPrefix(displayName, channelName string) string {
	normalizedDisplayName := normalizeValue(displayName)
	normalizedChannelName := normalizeValue(channelName)

	for _, prefix := range c.restrictedPrefixes {
		if strings.HasPrefix(normalizedDisplayName, prefix) || strings.HasPrefix(normalizedChannelName, prefix) {
			return prefix
		}
	}

	return ""
}

func parseRestrictedPrefixes(value string) []string {
	prefixes := make([]string, 0)

	for _, part := range strings.FieldsFunc(value, splitRestrictedPrefix) {
		normalizedPrefix := normalizeValue(part)
		if normalizedPrefix == "" {
			continue
		}

		prefixes = append(prefixes, normalizedPrefix)
	}

	return prefixes
}

func splitRestrictedPrefix(r rune) bool {
	return r == ',' || r == '\n' || r == '\r' || r == ';'
}

func (c configuration) notificationMessage(matchedPrefix string) string {
	message := strings.TrimSpace(c.RejectionMessage)
	if message != "" {
		return message
	}

	return defaultRejectionMessage + " Restricted prefix: " + matchedPrefix
}

func normalizeValue(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func main() {
	plugin.ClientMain(&Plugin{})
}
