class Item < ActiveRecord::Base
  include PaperclipWrapper

  STATUS_NORMAL  = 10.freeze
  STATUS_LOST    = 20.freeze
  STATUS_DAMAGED = 30.freeze
  
  PURPOSE_SHARE = 10.freeze
  PURPOSE_GIFT  = 20.freeze
  
  PURPOSES = {
    PURPOSE_SHARE => 'share',
    PURPOSE_GIFT  => 'gift'
  }

  STATUSES = {
    STATUS_NORMAL     => 'normal',
    STATUS_LOST       => 'lost',
    STATUS_DAMAGED    => 'damaged'
  }
  
  STATUSES_VISIBLE_TO_OTHER_USERS = [ STATUS_NORMAL, STATUS_DAMAGED ]
  REQUESTABLE_STATUSES = [ STATUS_NORMAL ]
  
  has_many :item_requests
  belongs_to :owner, :polymorphic => true

  has_many :activity_logs, :as => :action_object
  has_many :activity_logs_as_related, :as => :related

  has_many :event_logs, :as => :action_object
  has_many :event_logs_as_related, :as => :related

  has_attachment :photo,
                 :styles => {
                   :large => "600x600>",
                   :medium => "300x300>",
                   :small => "100x100>",
                   :square => "50x50#"
                  },
                 :default_url => "/images/noimage-:style.png"

  # has_attached_file :photo,
  #                   :styles => {
  #                     :large => "600x600>",
  #                     :medium => "300x300>",
  #                     :small => "100x100>",
  #                     :square => "50x50#"
  #                    },
  #                   :storage => :s3,
  #                   :s3_credentials => S3_CREDENTIALS,
  #                   :path => "item-photos/:id-:basename-:style.:extension",
  #                   :default_url => "/images/noimage-:style.png"                    

  validates_presence_of :item_type, :name, :owner_id, :owner_type, :status
  validates_inclusion_of :status, :in => STATUSES.keys, :message => " must be in #{STATUSES.values.join ', '}"
  
  #after_create :create_entity_for_item
  
  # validates_attachment_presence :photo
  validates_attachment_size :photo, :less_than => 1.megabyte
  validates_attachment_content_type :photo, :content_type => /image\//
  
  scope :without_deleted, :conditions => { :deleted_at => nil }
  scope :only_normal, :conditions => { :status => STATUS_NORMAL }
  scope :only_lost, :conditions => { :status => STATUS_LOST }
  scope :only_damaged, :conditions => { :status => STATUS_DAMAGED }
  scope :visible_to_other_users, where("status IN (#{STATUSES_VISIBLE_TO_OTHER_USERS.join(",")})")

  def is_owner?(entity)
    self.owner == entity
  end
  
  def has_photo?
    self.photo.nil?
  end

  def self.search(search, person_id)
    if search.empty?
        nil
    else
        items_sql = "select distinct resource_id from resource_networks where entity_id in (select entity_id from people_networks where person_id = #{person_id} and entity_type_id = 7)"     
        words = search.split(/[ ]/)
        item_type_like = words.map{|k| "item_type LIKE '%#{k}%' " }.join(" AND ")
        item_name_like = words.map{|k| "name LIKE '%#{k}%'" }.join(" AND ")
        item_desc_like = words.map{|k| "description LIKE '%#{k}%'" }.join(" AND ")
        sql_like = "(" + item_type_like + ") OR (" + item_name_like + ") OR (" + item_desc_like + ")"
        search_sql = "select id from items where id in (#{items_sql}) and (#{sql_like})"
        items_ids = ActiveRecord::Base.connection.execute(search_sql) 
        item_ids = items_ids.map{|i| i["id"]}
        Item.find(:all, :conditions => ["id IN (?)", item_ids])
    end
  end
  
  def transfer_ownership_to(entity)
    self.owner = entity
    save!
  end
  
  def in_trusted_network_for_person?(person)
    self.owner.trusts?(person)
  end
  
  def create_entity_for_item
    Entity.create!(:entity_type_id => EntityType::ITEM_ENTITY, :specific_entity_id => self.id)
  end
  
  def active_request_by?(user)
    item_request = ItemRequest.find(:last, :conditions => ["requester_id =? and requester_type=? and item_id=?", user.person.id,"Person", self.id])
    item_request.nil? ? false : ItemRequest::ACTIVE_STATUSES.include?(item_request.status)    
  end
  
  def purpose?
    PURPOSES[self.purpose]
  end
  
  def deleted?
    !deleted_at.nil?
  end
  
  def delete
    self.deleted_at = Time.zone.now
    save!
  end

  def restore
    self.deleted_at = nil
    save!
  end

  # #######
  # Status related methods
  # #######

  def status_name
    STATUSES[status]
  end

  def normal?
    self.status == STATUS_NORMAL
  end

  def lost?
    self.status == STATUS_LOST
  end

  def damaged?
    self.status == STATUS_DAMAGED
  end
  
  def deleted?
    self.deleted_at != nil
  end
  
  def damaged!
    self.status = STATUS_DAMAGED
    save!
    EventLog.create_news_event_log(self.owner, nil,  self , EventType.item_damaged)
  end

  def normal!
    self.status = STATUS_NORMAL
    save!
    EventLog.create_news_event_log(self.owner, nil,  self , EventType.item_repaired)
  end

  def lost!
    self.status = STATUS_LOST
    save!
  end
  
  def can_be_requested?
    REQUESTABLE_STATUSES.include? self.status
  end
  
  # #######
  # Purpose related methods
  # #######
  def share?
    self.purpose == PURPOSE_SHARE
  end
    
  def gift?
    self.purpose == PURPOSE_GIFT
  end
    
  def share!
    self.purpose = PURPOSE_SHARE
    save!
  end
  
  def gift!
    self.purpose = PURPOSE_GIFT
    save!
  end
  
  def create_new_item_event_log
    #EventLog.create_news_event_log(self.owner, nil,  self , EventType.add_item)
  end

  def create_new_item_activity_log
    ActivityLog.create_add_item_activity_log(self)
  end
  
  # #######
  # Metods related to item availability - true/false, if item is available
  # #######
  
  def available!
    self.available = true
    save!
  end
  
  def in_use!
    self.available = false
    save!
  end
  
  def available?
    self.available
  end
  
  def purpose_update_available?
    self.available?
  end
  
  def public_activities
     ActivityLog.item_public_activities(self).order("created_at desc").take(7)
  end   
  
end
