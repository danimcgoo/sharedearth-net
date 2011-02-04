class User < ActiveRecord::Base
  has_one :person

  validates_presence_of :provider, :uid, :nickname
  validates_uniqueness_of :uid, :scope => :provider

  def self.create_with_omniauth(auth)
    create! do |user|
      user.provider = auth["provider"]
      user.uid = auth["uid"]
      user.nickname = auth["user_info"]["nickname"]
      user.create_person(:name => auth["user_info"]["name"])
    end
  end
  
  # Available avatar sizes
  # square (50x50, Facebook default)
  # small  (50 pixels wide, variable height)
  # large (about 200 pixels wide, variable height)
  def avatar(avatar_size = nil)
    "http://graph.facebook.com/#{uid}/picture/"+(avatar_size ? "?type=#{avatar_size}" : "")
  end
end