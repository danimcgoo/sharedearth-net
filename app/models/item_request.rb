class ItemRequest < ActiveRecord::Base
  acts_as_commentable

  STATUS_REQUESTED = 10.freeze
  STATUS_ACCEPTED  = 20.freeze
  STATUS_COMPLETED = 30.freeze
  STATUS_REJECTED  = 40.freeze
  STATUS_CANCELED  = 50.freeze
  STATUS_COLLECTED = 60.freeze
  STATUS_RECALL    = 70.freeze
  STATUS_RETURN    = 80.freeze
  STATUS_ACKNOWLEDGED = 90.freeze
  STATUS_RETURNED     = 100.freeze
  STATUS_SHAREAGE     = 110.freeze

  STATUSES = {
    STATUS_REQUESTED  => 'requested',
    STATUS_ACCEPTED   => 'accepted',
    STATUS_COMPLETED  => 'completed',
    STATUS_REJECTED  => 'rejected',
    STATUS_CANCELED  => 'canceled',
    STATUS_COLLECTED  => 'collected',
    STATUS_RECALL    => 'recalled',
    STATUS_RETURN    => 'return',
    STATUS_ACKNOWLEDGED => 'acknowledged',
    STATUS_RETURNED      => 'returned',
    STATUS_SHAREAGE   => 'shareage'
  }

  ACTIVE_STATUSES = [ STATUS_REQUESTED, STATUS_ACCEPTED, STATUS_COLLECTED, STATUS_RECALL, STATUS_RETURN, STATUS_ACKNOWLEDGED ]

  belongs_to :item
  belongs_to :requester, :polymorphic => true
  belongs_to :gifter, :polymorphic => true

  has_many :activity_logs, :as => :related
  has_many :event_logs, :as => :relatedcan
  has_many :feedbacks

  after_create :create_new_item_request_activity_log

  scope :involves, lambda { |entity| where("(requester_id = ? AND requester_type = ?) OR (gifter_id = ? AND gifter_type = ?) ", entity.id, entity.class.to_s, entity.id, entity.class.to_s) }
  scope :involves_as_requester, lambda { |entity| where("requester_id = ? AND requester_type = ?", entity.id, entity.class.to_s) }
  scope :involves_as_gifter, lambda { |entity| where("gifter_id = ? AND gifter_type = ?", entity.id, entity.class.to_s) }
  scope :answered_gifter, lambda { |entity| where("gifter_id = ? AND gifter_type = ? and status IN (?)", entity.id, entity.class.to_s, [STATUS_ACCEPTED, STATUS_COLLECTED, STATUS_COMPLETED]) }
  scope :active, where("status IN (#{ACTIVE_STATUSES.join(",")})")
  scope :unanswered, where(:status => STATUS_REQUESTED)
  scope :shareage, where(:status => STATUS_SHAREAGE)
  scope :active_shareage, where("status IN (?)", [STATUS_SHAREAGE, STATUS_RETURN, STATUS_RECALL])
  scope :answered, where(:status => [STATUS_ACCEPTED, STATUS_COLLECTED, STATUS_COMPLETED])
  scope :older_than_2_weeks, where("created_at > ? and created_at < ? and status = ?",15.days.ago, 14.days.ago, STATUS_COMPLETED)
  scope :requested_item, lambda { |entity| where("item_id = ? and status IN (?)", entity.id, [STATUS_REQUESTED]) }
  scope :involves_item, lambda { |entity| where("item_id = ?", entity.id) }
  scope :collected, where(:status => STATUS_COLLECTED)

  # validates_presence_of :description
  validates_presence_of :requester_id, :requester_type
  validates_presence_of :gifter_id, :gifter_type
  validates_presence_of :item_id, :status
  validates_inclusion_of :status, :in => STATUSES.keys, :message => " must be in #{STATUSES.values.join ', '}"

  def requester?(requester)
    self.requester == requester
  end

  def gifter?(gifter)
    self.gifter == gifter
  end

  def involved?(entity)
  	(self.gifter == entity) || (self.requester == entity)
  end

  def self.new_by_requester(params, requester)
    item_request           = self.new(params)
    item_request.requester = requester
    item_request.gifter    = item_request.item.owner
    item_request.status    = ItemRequest::STATUS_REQUESTED
    item_request
  end

  def both_parties_left_feedback?
    self.feedbacks.count == 2
  end

  #TODO test this
  def feedback_from_gifter?
    feedback = Feedback.find_by_item_request_id_and_person_id(self.id, self.gifter.id)
    feedback.feedback.to_i
  end

  def feedback_from_requester?
    feedback = Feedback.find_by_item_request_id_and_person_id(self.id, self.requester.id)
    feedback.feedback.to_i
  end

  # #######
  # Status related methods
  # #######

  def status_name
    STATUSES[status]
  end

  def accept!
    return if !(self.status == STATUS_REQUESTED)
    self.item.hidden! if self.item.is_shareage?
    self.status = STATUS_ACCEPTED
    save!
    decline_all_for_item(item)
    case self.item.purpose?
      when Item::PURPOSES[Item::PURPOSE_SHARE]
        create_item_request_accepted_activity_log
      when Item::PURPOSES[Item::PURPOSE_GIFT]
        create_gift_request_accepted_activity_log
      when Item::PURPOSES[Item::PURPOSE_SHAREAGE]
        create_shareage_request_accepted_activity_log
      else
         #
    end
    self.item.in_use!
    self.item.owner.reputation_rating.increase_requests_answered_count
  end

  def reject!
    return if !(self.status == STATUS_REQUESTED)
    self.status = STATUS_REJECTED
    save!
    case self.item.purpose?
      when Item::PURPOSES[Item::PURPOSE_SHARE]
        create_item_request_rejected_activity_log
      when Item::PURPOSES[Item::PURPOSE_GIFT]
        create_gift_request_rejected_activity_log
      when Item::PURPOSES[Item::PURPOSE_SHAREAGE]
        create_shareage_request_rejected_activity_log
      else
         #
    end
    self.item.available!
    self.item.owner.reputation_rating.increase_requests_answered_count
  end

  def cancel!(person_initiator)
    return unless ACTIVE_STATUSES.include? self.status
    @person_initiator = person_initiator.id
    if self.accepted? && (self.requester.id == @person_initiator)
      self.update_reputation_for_parties_involved
    end
    case self.item.purpose?
      when Item::PURPOSES[Item::PURPOSE_SHARE]
        create_item_request_canceled_activity_log
      when Item::PURPOSES[Item::PURPOSE_GIFT]
        create_gift_request_canceled_activity_log
      when Item::PURPOSES[Item::PURPOSE_SHAREAGE]
        create_shareage_request_canceled_activity_log
      else
         #
    end
    self.item.available!
    self.item.unhide! if self.item.is_shareage?
    self.status = STATUS_CANCELED
    save!
  end

  def collected!
    return if !(self.status == STATUS_ACCEPTED)
    item = self.item
    self.item.gift? ? item.available! : item.in_use!
    self.update_reputation_for_parties_involved if self.item.gift?
    if self.item.is_shareage?
      self.item.change_resource_to_gifter
      self.item.add_to_resource_network_for_possessor(self.requester)
      self.item.shareage!
    end
    item_type_based_status
  end

  def complete!(person_initiator)
    return if !(self.status == STATUS_ACCEPTED || self.status == STATUS_COLLECTED )
    @person_initiator = person_initiator.id
    self.item.available!
    self.update_reputation_for_parties_involved
    self.status = STATUS_COMPLETED
    save!
    self.item.share? ? create_item_request_completed_activity_log : create_gift_request_completed_activity_log
    create_sharing_event_log
  end

  def recall!
    return if !(self.status == STATUS_SHAREAGE)
    self.status = STATUS_RECALL
    save!
    create_shareage_request_recall_activity_log
  end

  def return!
    return if !(self.status == STATUS_SHAREAGE)
    self.status = STATUS_RETURN
    save!
    create_shareage_request_return_activity_log
  end

  def cancel_recall!
    return if !(self.status == STATUS_RECALL)
    self.status = STATUS_SHAREAGE
    save!
    create_shareage_request_cancel_recall_activity_log
  end

  def cancel_return!
    return if !(self.status == STATUS_RETURN)
    self.status = STATUS_SHAREAGE
    save!
    create_shareage_request_cancel_return_activity_log
  end

  def acknowledge!
    return if !(self.status == STATUS_RECALL) && !(self.status == STATUS_RETURN)
    previous_state = self.status
    self.status = STATUS_ACKNOWLEDGED
    save!
    if previous_state == STATUS_RECALL
      create_shareage_request_acknowledged_activity_log
    else
      create_shareage_request_return_acknowledged_activity_log
    end
  end

  def returned!
    return if !(self.status == STATUS_ACKNOWLEDGED)
    self.status = STATUS_RETURNED
    save!
    create_shareage_request_returned_activity_log
    self.item.remove_resource_for_possessor
    self.item.change_resource_to_gifter_and_possessor
    self.item.unhide!
    self.item.available!
    self.item.normal!
    self.update_reputation_for_parties_involved
    create_shareage_event_log
  end

  def update_reputation_for_parties_involved
      self.gifter.reputation_rating.increase_gift_actions_count
      self.gifter.reputation_rating.increase_total_actions_count
      self.requester.reputation_rating.increase_total_actions_count
      self.gifter.reputation_rating.increase_distinct_people_count unless already_interacted?(self.gifter, self.requester) || canceled_requests_involving(self.gifter, self.requester)
  end

  #CHECK IF SOME COMPLETED REQUEST WITH OTHER PERSON EXISTS AND IF THERE IS INTERACTION WHEN REQUEST WAS ACCEPTED AND THEN CANCELED BY REQUESTER
  def already_interacted?(first_person, second_person)
    completed = ItemRequest.find(:first, :conditions => ["gifter_id=? and gifter_type=? and requester_id=? and requester_type=? and status IN (?)",
                                                          first_person.id, "Person", second_person.id, "Person", [STATUS_COMPLETED]])
    completed.nil? ? false : true
  end

  def canceled_requests_involving(first_person, second_person)
    canceled = ItemRequest.find(:all, :conditions => ["gifter_id=? and gifter_type=? and requester_id=? and requester_type=? and status IN (?)",
                                                       first_person.id, "Person", second_person.id, "Person", [STATUS_ACCEPTED]])
    canceled.each do |request|
      activity_log = ActivityLog.find(:first, :conditions => ["primary_id =? and primary_type=? and secondary_id=? and secondary_type=? and action_object_id=? and event_type_id IN (?)",
                                                              second_person.id, "Person", first_person.id, "Person", request.item_id, EventType.activity_canceled])
      return true unless activity_log.nil?
    end
    false
  end

  def requested?
    self.status == STATUS_REQUESTED
  end

  def accepted?
    self.status == STATUS_ACCEPTED
  end

  def rejected?
    self.status == STATUS_REJECTED
  end

  def canceled?
    self.status == STATUS_CANCELED
  end

  def collected?
    self.status == STATUS_COLLECTED
  end

  def completed?
    self.status == STATUS_COMPLETED
  end

  def recall?
    self.status == STATUS_RECALL
  end

  def in_return?
    self.status == STATUS_RETURN
  end

  def acknowledged?
    self.status == STATUS_ACKNOWLEDGED
  end

  def returned?
    self.status == STATUS_RETURNED
  end

  def shareage?
    self.status == STATUS_SHAREAGE
  end

  def has_left_feedback?(person_id)
    !Feedback.exists_for?(self.id, person_id)
  end

  def leave_comment!(commentier)
    if self.requester?(commentier)
      comments_unread = ActivityLog.involves_request(self).comment_gifter_events.unread
    else
      comments_unread = ActivityLog.involves_request(self).comment_requester_events.unread
    end

    if comments_unread.empty?
    	create_item_request_comment_activity_log(commentier)
    end
  end

  private

  def item_type_based_status
    case self.item.purpose_type?
    when Item::PURPOSE_SHARE
      self.status = STATUS_COLLECTED
      create_item_request_collected_activity_log
    when Item::PURPOSE_GIFT
      self.status = STATUS_COMPLETED
      change_ownership
      create_gift_request_completed_activity_log
      create_gifting_event_log
    when Item::PURPOSE_SHAREAGE
      self.status = STATUS_SHAREAGE
      create_shareage_request_collected_activity_log
    else
      #
    end
    save!
  end

  def change_ownership
    self.item.transfer_ownership_to(self.requester)
    resource = ResourceNetwork.item(self.item).first
    resource.update_attributes(:entity_id => self.requester_id)
  end

  def create_sharing_event_log
    EventLog.create_news_event_log(self.requester, self.gifter,  self.item , EventType.sharing, self)
  end

  def create_gifting_event_log
    EventLog.create_news_event_log(self.requester, self.gifter,  self.item , EventType.gifting, self)
  end

  def create_shareage_event_log
    EventLog.create_news_event_log(self.requester, self.gifter,  self.item , EventType.shareage, self)
  end

  def create_new_item_request_activity_log
    if self.item.is_shareage?
      ActivityLog.create_new_shareage_item_request_activity_log(self)
    else
      ActivityLog.create_new_item_request_activity_log(self)
    end
    self.item.owner.reputation_rating.increase_requests_received_count
  end

  def create_item_request_accepted_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.item_request_accepted_gifter, EventType.item_request_accepted_requester)
  end

  def create_item_request_rejected_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.item_request_rejected_gifter, EventType.item_request_rejected_requester)
  end

  def create_item_request_canceled_activity_log
    if self.requester_id == @person_initiator
      ActivityLog.create_item_request_activity_log(self, EventType.item_requester_canceled_gifter, EventType.item_requester_canceled_requester)
    else
      ActivityLog.create_item_request_activity_log(self, EventType.item_gifter_canceled_gifter, EventType.item_gifter_canceled_requester)
    end
  end

  def create_item_request_collected_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.item_request_collected_gifter, EventType.item_request_collected_requester)
  end

  def create_item_request_completed_activity_log
    if self.requester_id == @person_initiator
      ActivityLog.create_item_request_activity_log(self, EventType.item_request_completed_gifter, EventType.item_request_completed_requester)
    else
      ActivityLog.create_item_request_activity_log(self, EventType.item_gifter_completed_gifter, EventType.item_gifter_completed_requester)
    end
  end

  #GIFT ITEMS RELATED ACTIVITY LOG

  def create_gift_request_accepted_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.gift_accepted_gifter, EventType.gift_accepted_requester)
  end

  def create_gift_request_rejected_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.gift_rejected_gifter, EventType.gift_rejected_requester)
  end

  def create_gift_request_canceled_activity_log
    if self.requester_id == @person_initiator
      ActivityLog.create_item_request_activity_log(self, EventType.gift_requester_canceled_gifter, EventType.gift_requester_canceled_requester)
    else
      ActivityLog.create_item_request_activity_log(self, EventType.gift_gifter_canceled_gifter, EventType.gift_gifter_canceled_requester)
    end
  end

  def create_gift_request_completed_activity_log
    if self.requester_id == @person_initiator
      ActivityLog.create_item_request_activity_log(self, EventType.gift_requester_completed_gifter, EventType.gift_requester_completed_requester)
    else
      ActivityLog.create_item_request_activity_log(self, EventType.gift_gifter_completed_gifter, EventType.gift_requester_completed_requester)
    end
  end

  #SHAREAGE ITEMS RELATED ACTIVITY LOG
  def create_shareage_request_accepted_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.shareage_accepted_gifter, EventType.shareage_accepted_requester)
  end

  def create_shareage_request_rejected_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.shareage_rejected_gifter, EventType.shareage_rejected_requester)
  end

  def create_shareage_request_canceled_activity_log
    if self.requester_id == @person_initiator
      ActivityLog.create_item_request_activity_log(self, EventType.shareage_requester_canceled_gifter, EventType.shareage_requester_canceled_requester)
    else
      ActivityLog.create_item_request_activity_log(self, EventType.shareage_gifter_canceled_gifter, EventType.shareage_gifter_canceled_requester)
    end
  end

  def create_shareage_request_collected_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.collected_shareage_gifter, EventType.collected_shareage_requester)
  end

  def create_shareage_request_recall_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.recall_shareage_gifter, EventType.recall_shareage_requester)
  end

  def create_shareage_request_return_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.return_shareage_gifter, EventType.return_shareage_requester)
  end

  def create_shareage_request_cancel_recall_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.cancel_recall_shareage_gifter, EventType.cancel_recall_shareage_requester)
  end

  def create_shareage_request_cancel_return_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.cancel_return_shareage_gifter, EventType.cancel_return_shareage_requester)
  end

  def create_shareage_request_acknowledged_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.acknowledge_shareage_gifter, EventType.acknowledge_shareage_requester)
  end

  def create_shareage_request_return_acknowledged_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.acknowledge_return_shareage_gifter, EventType.acknowledge_return_shareage_requester)
  end

  def create_shareage_request_returned_activity_log
    ActivityLog.create_item_request_activity_log(self, EventType.returned_shareage_gifter, EventType.returned_shareage_requester)
  end

  #MUTUAL RELATED ACTIVITY LOGS

  def create_item_request_comment_activity_log(commentier)
    ActivityLog.create_item_request_comment_activity_log(self, commentier)
  end

  def decline_all_for_item(item)
    requests_active_item = ItemRequest.requested_item(item)
    requests_active_item.each { |r| r.reject! }
  end
end
