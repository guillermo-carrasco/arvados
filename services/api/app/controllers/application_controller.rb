module ApiTemplateOverride
  def allowed_to_render?(fieldset, field, model, options)
    if options[:select]
      return options[:select].include? field.to_s
    end
    super
  end
end

class ActsAsApi::ApiTemplate
  prepend ApiTemplateOverride
end

require 'load_param'
require 'record_filters'

class ApplicationController < ActionController::Base
  include CurrentApiClient
  include ThemesForRails::ActionController
  include LoadParam
  include RecordFilters

  respond_to :json
  protect_from_forgery

  ERROR_ACTIONS = [:render_error, :render_not_found]

  before_filter :respond_with_json_by_default
  before_filter :remote_ip
  before_filter :load_read_auths
  before_filter :require_auth_scope, except: ERROR_ACTIONS

  before_filter :catch_redirect_hint
  before_filter(:find_object_by_uuid,
                except: [:index, :create] + ERROR_ACTIONS)
  before_filter :load_limit_offset_order_params, only: [:index, :contents]
  before_filter :load_where_param, only: [:index, :contents]
  before_filter :load_filters_param, only: [:index, :contents]
  before_filter :find_objects_for_index, :only => :index
  before_filter :reload_object_before_update, :only => :update
  before_filter(:render_404_if_no_object,
                except: [:index, :create] + ERROR_ACTIONS)

  theme :select_theme

  attr_accessor :resource_attrs

  begin
    rescue_from(Exception,
                ArvadosModel::PermissionDeniedError,
                :with => :render_error)
    rescue_from(ActiveRecord::RecordNotFound,
                ActionController::RoutingError,
                ActionController::UnknownController,
                AbstractController::ActionNotFound,
                :with => :render_not_found)
  end

  def index
    @objects.uniq!(&:id) if @select.nil? or @select.include? "id"
    if params[:eager] and params[:eager] != '0' and params[:eager] != 0 and params[:eager] != ''
      @objects.each(&:eager_load_associations)
    end
    render_list
  end

  def show
    render json: @object.as_api_response
  end

  def create
    @object = model_class.new resource_attrs
    @object.save!
    show
  end

  def update
    attrs_to_update = resource_attrs.reject { |k,v|
      [:kind, :etag, :href].index k
    }
    @object.update_attributes! attrs_to_update
    show
  end

  def destroy
    @object.destroy
    show
  end

  def catch_redirect_hint
    if !current_user
      if params.has_key?('redirect_to') then
        session[:redirect_to] = params[:redirect_to]
      end
    end
  end

  def render_404_if_no_object
    render_not_found "Object not found" if !@object
  end

  def render_error(e)
    logger.error e.inspect
    if e.respond_to? :backtrace and e.backtrace
      logger.error e.backtrace.collect { |x| x + "\n" }.join('')
    end
    if @object and @object.errors and @object.errors.full_messages and not @object.errors.full_messages.empty?
      errors = @object.errors.full_messages
    else
      errors = [e.inspect]
    end
    status = e.respond_to?(:http_status) ? e.http_status : 422
    send_error(*errors, status: status)
  end

  def render_not_found(e=ActionController::RoutingError.new("Path not found"))
    logger.error e.inspect
    send_error("Path not found", status: 404)
  end

  protected

  def send_error(*args)
    if args.last.is_a? Hash
      err = args.pop
    else
      err = {}
    end
    err[:errors] ||= args
    err[:error_token] = [Time.now.utc.to_i, "%08x" % rand(16 ** 8)].join("+")
    status = err.delete(:status) || 422
    logger.error "Error #{err[:error_token]}: #{status}"
    render json: err, status: status
  end

  def find_objects_for_index
    @objects ||= model_class.readable_by(*@read_users)
    apply_where_limit_order_params
  end

  def apply_filters
    ft = record_filters @filters, @objects.table_name
    if ft[:cond_out].any?
      @objects = @objects.where(ft[:cond_out].join(' AND '), *ft[:param_out])
    end
  end

  def apply_where_limit_order_params
    apply_filters

    ar_table_name = @objects.table_name
    if @where.is_a? Hash and @where.any?
      conditions = ['1=1']
      @where.each do |attr,value|
        if attr.to_s == 'any'
          if value.is_a?(Array) and
              value.length == 2 and
              value[0] == 'contains' then
            ilikes = []
            model_class.searchable_columns('ilike').each do |column|
              # Including owner_uuid in an "any column" search will
              # probably just return a lot of false positives.
              next if column == 'owner_uuid'
              ilikes << "#{ar_table_name}.#{column} ilike ?"
              conditions << "%#{value[1]}%"
            end
            if ilikes.any?
              conditions[0] << ' and (' + ilikes.join(' or ') + ')'
            end
          end
        elsif attr.to_s.match(/^[a-z][_a-z0-9]+$/) and
            model_class.columns.collect(&:name).index(attr.to_s)
          if value.nil?
            conditions[0] << " and #{ar_table_name}.#{attr} is ?"
            conditions << nil
          elsif value.is_a? Array
            if value[0] == 'contains' and value.length == 2
              conditions[0] << " and #{ar_table_name}.#{attr} like ?"
              conditions << "%#{value[1]}%"
            else
              conditions[0] << " and #{ar_table_name}.#{attr} in (?)"
              conditions << value
            end
          elsif value.is_a? String or value.is_a? Fixnum or value == true or value == false
            conditions[0] << " and #{ar_table_name}.#{attr}=?"
            conditions << value
          elsif value.is_a? Hash
            # Not quite the same thing as "equal?" but better than nothing?
            value.each do |k,v|
              if v.is_a? String
                conditions[0] << " and #{ar_table_name}.#{attr} ilike ?"
                conditions << "%#{k}%#{v}%"
              end
            end
          end
        end
      end
      if conditions.length > 1
        conditions[0].sub!(/^1=1 and /, '')
        @objects = @objects.
          where(*conditions)
      end
    end

    @objects = @objects.select(@select.map { |s| "#{table_name}.#{ActiveRecord::Base.connection.quote_column_name s.to_s}" }.join ", ") if @select
    @objects = @objects.order(@orders.join ", ") if @orders.any?
    @objects = @objects.limit(@limit)
    @objects = @objects.offset(@offset)
    @objects = @objects.uniq(@distinct) if not @distinct.nil?
  end

  def resource_attrs
    return @attrs if @attrs
    @attrs = params[resource_name]
    if @attrs.is_a? String
      @attrs = Oj.load @attrs, symbol_keys: true
    end
    unless @attrs.is_a? Hash
      message = "No #{resource_name}"
      if resource_name.index('_')
        message << " (or #{resource_name.camelcase(:lower)})"
      end
      message << " hash provided with request"
      raise ArgumentError.new(message)
    end
    %w(created_at modified_by_client_uuid modified_by_user_uuid modified_at).each do |x|
      @attrs.delete x.to_sym
    end
    @attrs = @attrs.symbolize_keys if @attrs.is_a? HashWithIndifferentAccess
    @attrs
  end

  # Authentication
  def load_read_auths
    @read_auths = []
    if current_api_client_authorization
      @read_auths << current_api_client_authorization
    end
    # Load reader tokens if this is a read request.
    # If there are too many reader tokens, assume the request is malicious
    # and ignore it.
    if request.get? and params[:reader_tokens] and
        params[:reader_tokens].size < 100
      @read_auths += ApiClientAuthorization
        .includes(:user)
        .where('api_token IN (?) AND
                (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)',
               params[:reader_tokens])
        .all
    end
    @read_auths.select! { |auth| auth.scopes_allow_request? request }
    @read_users = @read_auths.map { |auth| auth.user }.uniq
  end

  def require_login
    if not current_user
      respond_to do |format|
        format.json { send_error("Not logged in", status: 401) }
        format.html { redirect_to '/auth/joshid' }
      end
      false
    end
  end

  def admin_required
    unless current_user and current_user.is_admin
      send_error("Forbidden", status: 403)
    end
  end

  def require_auth_scope
    if @read_auths.empty?
      if require_login != false
        send_error("Forbidden", status: 403)
      end
      false
    end
  end

  def respond_with_json_by_default
    html_index = request.accepts.index(Mime::HTML)
    if html_index.nil? or request.accepts[0...html_index].include?(Mime::JSON)
      request.format = :json
    end
  end

  def model_class
    controller_name.classify.constantize
  end

  def resource_name             # params[] key used by client
    controller_name.singularize
  end

  def table_name
    controller_name
  end

  def find_object_by_uuid
    if params[:id] and params[:id].match /\D/
      params[:uuid] = params.delete :id
    end
    @where = { uuid: params[:uuid] }
    @offset = 0
    @limit = 1
    @orders = []
    @filters = []
    @objects = nil
    find_objects_for_index
    @object = @objects.first
  end

  def reload_object_before_update
    # This is necessary to prevent an ActiveRecord::ReadOnlyRecord
    # error when updating an object which was retrieved using a join.
    if @object.andand.readonly?
      @object = model_class.find_by_uuid(@objects.first.uuid)
    end
  end

  def load_json_value(hash, key, must_be_class=nil)
    if hash[key].is_a? String
      hash[key] = Oj.load(hash[key], symbol_keys: false)
      if must_be_class and !hash[key].is_a? must_be_class
        raise TypeError.new("parameter #{key.to_s} must be a #{must_be_class.to_s}")
      end
    end
  end

  def self.accept_attribute_as_json(attr, must_be_class=nil)
    before_filter lambda { accept_attribute_as_json attr, must_be_class }
  end
  accept_attribute_as_json :properties, Hash
  accept_attribute_as_json :info, Hash
  def accept_attribute_as_json(attr, must_be_class)
    if params[resource_name] and resource_attrs.is_a? Hash
      if resource_attrs[attr].is_a? Hash
        # Convert symbol keys to strings (in hashes provided by
        # resource_attrs)
        resource_attrs[attr] = resource_attrs[attr].
          with_indifferent_access.to_hash
      else
        load_json_value(resource_attrs, attr, must_be_class)
      end
    end
  end

  def self.accept_param_as_json(key, must_be_class=nil)
    prepend_before_filter lambda { load_json_value(params, key, must_be_class) }
  end
  accept_param_as_json :reader_tokens, Array

  def render_list
    @object_list = {
      :kind  => "arvados##{(@response_resource_name || resource_name).camelize(:lower)}List",
      :etag => "",
      :self_link => "",
      :offset => @offset,
      :limit => @limit,
      :items => @objects.as_api_response(nil, {select: @select})
    }
    if @objects.respond_to? :except
      @object_list[:items_available] = @objects.
        except(:limit).except(:offset).
        count(:id, distinct: true)
    end
    render json: @object_list
  end

  def remote_ip
    # Caveat: this is highly dependent on the proxy setup. YMMV.
    if request.headers.has_key?('HTTP_X_REAL_IP') then
      # We're behind a reverse proxy
      @remote_ip = request.headers['HTTP_X_REAL_IP']
    else
      # Hopefully, we are not!
      @remote_ip = request.env['REMOTE_ADDR']
    end
  end

  def self._index_requires_parameters
    {
      filters: { type: 'array', required: false },
      where: { type: 'object', required: false },
      order: { type: 'array', required: false },
      select: { type: 'array', required: false },
      distinct: { type: 'boolean', required: false },
      limit: { type: 'integer', required: false, default: DEFAULT_LIMIT },
      offset: { type: 'integer', required: false, default: 0 },
    }
  end

  def client_accepts_plain_text_stream
    (request.headers['Accept'].split(' ') &
     ['text/plain', '*/*']).count > 0
  end

  def render *opts
    if opts.first
      response = opts.first[:json]
      if response.is_a?(Hash) &&
          params[:_profile] &&
          Thread.current[:request_starttime]
        response[:_profile] = {
          request_time: Time.now - Thread.current[:request_starttime]
        }
      end
    end
    super *opts
  end

  def select_theme
    return Rails.configuration.arvados_theme
  end
end
