package main

import (
	"slices"
	"strings"
	"sync"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

const (
	defaultChannelName      = "announcement,announcements"
	defaultRejectionMessage = "This is a read-only announcement channel. Only admins can post here."
)

type configuration struct {
	ChannelName            string
	RejectionMessage       string
	restrictedChannels     []string
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

	nextConfig.restrictedChannels = parseChannelNames(nextConfig.ChannelName)
	if len(nextConfig.restrictedChannels) == 0 {
		nextConfig.restrictedChannels = parseChannelNames(defaultChannelName)
	}

	p.configurationLock.Lock()
	p.configuration = nextConfig
	p.configurationLock.Unlock()

	return nil
}

func (p *Plugin) MessageWillBePosted(_ *plugin.Context, post *model.Post) (*model.Post, string) {
	if post == nil || post.UserId == "" || post.ChannelId == "" {
		return post, ""
	}

	channel, appErr := p.API.GetChannel(post.ChannelId)
	if appErr != nil {
		p.API.LogWarn(
			"announcement plugin failed to load channel; allowing post",
			"channel_id", post.ChannelId,
			"user_id", post.UserId,
			"error", appErr.Error(),
		)
		return post, ""
	}

	config := p.getConfiguration()
	if !config.isRestrictedChannel(channel.Name) {
		return post, ""
	}

	if p.API.HasPermissionTo(post.UserId, model.PermissionManageSystem) {
		return post, ""
	}

	if p.API.HasPermissionToChannel(post.UserId, post.ChannelId, model.PermissionManageChannelRoles) {
		return post, ""
	}

	return nil, config.rejectionMessage()
}

func (p *Plugin) MessageWillBeUpdated(_ *plugin.Context, newPost *model.Post, _ *model.Post) (*model.Post, string) {
	if newPost == nil || newPost.UserId == "" || newPost.ChannelId == "" {
		return newPost, ""
	}

	channel, appErr := p.API.GetChannel(newPost.ChannelId)
	if appErr != nil {
		p.API.LogWarn(
			"announcement plugin failed to load channel; allowing edit",
			"channel_id", newPost.ChannelId,
			"user_id", newPost.UserId,
			"error", appErr.Error(),
		)
		return newPost, ""
	}

	config := p.getConfiguration()
	if !config.isRestrictedChannel(channel.Name) {
		return newPost, ""
	}

	if p.API.HasPermissionTo(newPost.UserId, model.PermissionManageSystem) {
		return newPost, ""
	}

	if p.API.HasPermissionToChannel(newPost.UserId, newPost.ChannelId, model.PermissionManageChannelRoles) {
		return newPost, ""
	}

	return nil, config.rejectionMessage()
}

func (p *Plugin) getConfiguration() configuration {
	p.configurationLock.RLock()
	defer p.configurationLock.RUnlock()

	if p.configuration == nil {
		return configuration{}
	}

	return *p.configuration
}

func (c configuration) isRestrictedChannel(channelName string) bool {
	normalizedChannelName := normalizeChannelName(channelName)
	if normalizedChannelName == "" {
		return false
	}

	return slices.Contains(c.restrictedChannels, normalizedChannelName)
}

func parseChannelNames(value string) []string {
	names := make([]string, 0)

	for _, part := range strings.Split(value, ",") {
		normalizedName := normalizeChannelName(part)
		if normalizedName == "" {
			continue
		}

		names = append(names, normalizedName)
	}

	return names
}

func (c configuration) rejectionMessage() string {
	message := strings.TrimSpace(c.RejectionMessage)
	if message == "" {
		return defaultRejectionMessage
	}

	return message
}

func normalizeChannelName(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func main() {
	plugin.ClientMain(&Plugin{})
}
