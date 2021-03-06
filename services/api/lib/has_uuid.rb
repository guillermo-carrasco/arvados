module HasUuid

  def self.included(base)
    base.extend(ClassMethods)
    base.before_create :assign_uuid
    base.before_destroy :destroy_permission_links
    base.has_many :links_via_head, class_name: 'Link', foreign_key: :head_uuid, primary_key: :uuid, conditions: "not (link_class = 'permission')", dependent: :restrict
    base.has_many :links_via_tail, class_name: 'Link', foreign_key: :tail_uuid, primary_key: :uuid, conditions: "not (link_class = 'permission')", dependent: :restrict
  end

  module ClassMethods
    def uuid_prefix
      Digest::MD5.hexdigest(self.to_s).to_i(16).to_s(36)[-5..-1]
    end
    def generate_uuid
      [Server::Application.config.uuid_prefix,
       self.uuid_prefix,
       rand(2**256).to_s(36)[-15..-1]].
        join '-'
    end
  end

  protected

  def respond_to_uuid?
    self.respond_to? :uuid
  end

  def assign_uuid
    return true if !self.respond_to_uuid?
    if (uuid.is_a?(String) and uuid.length>0 and
        current_user and current_user.is_admin)
      return true
    end
    self.uuid = self.class.generate_uuid
  end

  def destroy_permission_links
    if uuid
      Link.destroy_all(['link_class=? and (head_uuid=? or tail_uuid=?)',
                        'permission', uuid, uuid])
    end
  end
end
