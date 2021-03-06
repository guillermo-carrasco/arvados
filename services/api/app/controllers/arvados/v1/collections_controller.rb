class Arvados::V1::CollectionsController < ApplicationController
  def create
    # Collections are owned by system_user. Creating a collection has
    # two effects: The collection is added if it doesn't already
    # exist, and a "permission" Link is added (if one doesn't already
    # exist) giving the current user (or specified owner_uuid)
    # permission to read it.
    owner_uuid = resource_attrs.delete(:owner_uuid) || current_user.uuid
    unless current_user.can? write: owner_uuid
      logger.warn "User #{current_user.andand.uuid} tried to set collection owner_uuid to #{owner_uuid}"
      raise ArvadosModel::PermissionDeniedError
    end

    # Check permissions on the collection manifest.
    # If any signature cannot be verified, return 403 Permission denied.
    api_token = current_api_client_authorization.andand.api_token
    signing_opts = {
      key: Rails.configuration.blob_signing_key,
      api_token: api_token,
      ttl: Rails.configuration.blob_signing_ttl,
    }
    resource_attrs[:manifest_text].lines.each do |entry|
      entry.split[1..-1].each do |tok|
        if /^[[:digit:]]+:[[:digit:]]+:/.match tok
          # This is a filename token, not a blob locator. Note that we
          # keep checking tokens after this, even though manifest
          # format dictates that all subsequent tokens will also be
          # filenames. Safety first!
        elsif Blob.verify_signature tok, signing_opts
          # OK.
        elsif Locator.parse(tok).andand.signature
          # Signature provided, but verify_signature did not like it.
          logger.warn "Invalid signature on locator #{tok}"
          raise ArvadosModel::PermissionDeniedError
        elsif Rails.configuration.permit_create_collection_with_unsigned_manifest
          # No signature provided, but we are running in insecure mode.
          logger.debug "Missing signature on locator #{tok} ignored"
        elsif Blob.new(tok).empty?
          # No signature provided -- but no data to protect, either.
        else
          logger.warn "Missing signature on locator #{tok}"
          raise ArvadosModel::PermissionDeniedError
        end
      end
    end

    # Remove any permission signatures from the manifest.
    resource_attrs[:manifest_text]
      .gsub!(/ [[:xdigit:]]{32}(\+[[:digit:]]+)?(\+\S+)/) { |word|
      word.strip!
      loc = Locator.parse(word)
      if loc
        " " + loc.without_signature.to_s
      else
        " " + word
      end
    }

    # Save the collection with the stripped manifest.
    act_as_system_user do
      @object = model_class.new resource_attrs.reject { |k,v| k == :owner_uuid }
      begin
        @object.save!
      rescue ActiveRecord::RecordNotUnique
        logger.debug resource_attrs.inspect
        if resource_attrs[:manifest_text] and resource_attrs[:uuid]
          @existing_object = model_class.
            where('uuid=? and manifest_text=?',
                  resource_attrs[:uuid],
                  resource_attrs[:manifest_text]).
            first
          @object = @existing_object || @object
        end
      end
      if @object
        link_attrs = {
          owner_uuid: owner_uuid,
          link_class: 'permission',
          name: 'can_read',
          head_uuid: @object.uuid,
          tail_uuid: owner_uuid
        }
        ActiveRecord::Base.transaction do
          if Link.where(link_attrs).empty?
            Link.create! link_attrs
          end
        end
      end
    end
    show
  end

  def show
    if current_api_client_authorization
      signing_opts = {
        key: Rails.configuration.blob_signing_key,
        api_token: current_api_client_authorization.api_token,
        ttl: Rails.configuration.blob_signing_ttl,
      }
      @object[:manifest_text]
        .gsub!(/ [[:xdigit:]]{32}(\+[[:digit:]]+)?(\+\S+)/) { |word|
        word.strip!
        loc = Locator.parse(word)
        if loc
          " " + Blob.sign_locator(word, signing_opts)
        else
          " " + word
        end
      }
    end
    render json: @object.as_api_response(:with_data)
  end

  def collection_uuid(uuid)
    m = /([a-f0-9]{32}(\+[0-9]+)?)(\+.*)?/.match(uuid)
    if m
      m[1]
    else
      nil
    end
  end

  def script_param_edges(visited, sp)
    case sp
    when Hash
      sp.each do |k, v|
        script_param_edges(visited, v)
      end
    when Array
      sp.each do |v|
        script_param_edges(visited, v)
      end
    when String
      return if sp.empty?
      m = collection_uuid(sp)
      if m
        generate_provenance_edges(visited, m)
      end
    end
  end

  def generate_provenance_edges(visited, uuid)
    m = collection_uuid(uuid)
    uuid = m if m

    if not uuid or uuid.empty? or visited[uuid]
      return ""
    end

    logger.debug "visiting #{uuid}"

    if m  
      # uuid is a collection
      Collection.readable_by(current_user).where(uuid: uuid).each do |c|
        visited[uuid] = c.as_api_response
        visited[uuid][:files] = []
        c.files.each do |f|
          visited[uuid][:files] << f
        end
      end

      Job.readable_by(current_user).where(output: uuid).each do |job|
        generate_provenance_edges(visited, job.uuid)
      end

      Job.readable_by(current_user).where(log: uuid).each do |job|
        generate_provenance_edges(visited, job.uuid)
      end
      
    else
      # uuid is something else
      rsc = ArvadosModel::resource_class_for_uuid uuid
      if rsc == Job
        Job.readable_by(current_user).where(uuid: uuid).each do |job|
          visited[uuid] = job.as_api_response
          script_param_edges(visited, job.script_parameters)
        end
      elsif rsc != nil
        rsc.where(uuid: uuid).each do |r|
          visited[uuid] = r.as_api_response
        end
      end
    end

    Link.readable_by(current_user).
      where(head_uuid: uuid, link_class: "provenance").
      each do |link|
      visited[link.uuid] = link.as_api_response
      generate_provenance_edges(visited, link.tail_uuid)
    end

    #puts "finished #{uuid}"
  end

  def provenance
    visited = {}
    generate_provenance_edges(visited, @object[:uuid])
    render json: visited
  end

  def generate_used_by_edges(visited, uuid)
    m = collection_uuid(uuid)
    uuid = m if m

    if not uuid or uuid.empty? or visited[uuid]
      return ""
    end

    logger.debug "visiting #{uuid}"

    if m  
      # uuid is a collection
      Collection.readable_by(current_user).where(uuid: uuid).each do |c|
        visited[uuid] = c.as_api_response
        visited[uuid][:files] = []
        c.files.each do |f|
          visited[uuid][:files] << f
        end
      end

      if uuid == "d41d8cd98f00b204e9800998ecf8427e+0"
        # special case for empty collection
        return
      end

      Job.readable_by(current_user).where(["jobs.script_parameters like ?", "%#{uuid}%"]).each do |job|
        generate_used_by_edges(visited, job.uuid)
      end
      
    else
      # uuid is something else
      rsc = ArvadosModel::resource_class_for_uuid uuid
      if rsc == Job
        Job.readable_by(current_user).where(uuid: uuid).each do |job|
          visited[uuid] = job.as_api_response
          generate_used_by_edges(visited, job.output)
        end
      elsif rsc != nil
        rsc.where(uuid: uuid).each do |r|
          visited[uuid] = r.as_api_response
        end
      end
    end

    Link.readable_by(current_user).
      where(tail_uuid: uuid, link_class: "provenance").
      each do |link|
      visited[link.uuid] = link.as_api_response
      generate_used_by_edges(visited, link.head_uuid)
    end

    #puts "finished #{uuid}"
  end

  def used_by
    visited = {}
    generate_used_by_edges(visited, @object[:uuid])
    render json: visited
  end

  protected
  def find_object_by_uuid
    super
    if !@object and !params[:uuid].match(/^[0-9a-f]+\+\d+$/)
      # Normalize the given uuid and search again.
      hash_part = params[:uuid].match(/^([0-9a-f]*)/)[1]
      collection = Collection.where('uuid like ?', hash_part + '+%').first
      if collection
        # We know the collection exists, and what its real uuid is in
        # the database. Now, throw out @objects and repeat the usual
        # lookup procedure. (Returning the collection at this point
        # would bypass permission checks.)
        @objects = nil
        @where = { uuid: collection.uuid }
        find_objects_for_index
        @object = @objects.first
      end
    end
  end
end
