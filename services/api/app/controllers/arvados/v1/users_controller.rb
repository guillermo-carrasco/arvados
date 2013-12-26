class Arvados::V1::UsersController < ApplicationController
  def current
    @object = current_user
    show
  end
  def system
    @object = system_user
    show
  end

  class ChannelStreamer
    Q_UPDATE_INTERVAL = 12
    def initialize(opts={})
      @opts = opts
    end
    def each
      return unless @opts[:channel]
      @redis = Redis.new(:timeout => 0)
      @redis.subscribe(@opts[:channel]) do |event|
        event.message do |channel, msg|
          yield msg + "\n"
        end
      end
    end
  end
      
  def event_stream
    channel = current_user.andand.uuid
    if current_user.andand.is_admin
      channel = params[:uuid] || channel
    end
    if client_accepts_plain_text_stream
      self.response.headers['Last-Modified'] = Time.now.ctime.to_s
      self.response_body = ChannelStreamer.new(channel: channel)
    else
      render json: {
        href: url_for(uuid: channel),
        comment: ('To retrieve the event stream as plain text, ' +
                  'use a request header like "Accept: text/plain"')
      }
    end
  end

  def activate
    if current_user.andand.is_admin && params[:uuid]
      @user = User.find params[:uuid]
    else
      @user = current_user
    end
    if not @user.is_active
      target_user_uuid = @user.uuid
      act_as_system_user do
        required_uuids = Link.where(owner_uuid: system_user_uuid,
                                    link_class: 'signature',
                                    name: 'require',
                                    tail_uuid: system_user_uuid,
                                    head_kind: 'arvados#collection').
          collect(&:head_uuid)
        signed_uuids = Link.where(owner_uuid: system_user_uuid,
                                  link_class: 'signature',
                                  name: 'click',
                                  tail_kind: 'arvados#user',
                                  tail_uuid: target_user_uuid,
                                  head_kind: 'arvados#collection',
                                  head_uuid: required_uuids).
          collect(&:head_uuid)
        todo_uuids = required_uuids - signed_uuids
        if todo_uuids == []
          @user.update_attributes is_active: true
          logger.info "User #{@user.uuid} activated"
        else
          logger.warn "User #{@user.uuid} called users.activate " +
            "before signing agreements #{todo_uuids.inspect}"
          raise ArgumentError.new \
          "Cannot activate without user agreements #{todo_uuids.inspect}."
        end
      end
    end
    @object = @user
    show
  end
end
