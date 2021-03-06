Then /^I should not have a new Item$/ do
  Item.count.should == 0
end

Given /^the logged person is the owner$/ do
  # This is very smelly, but for the time being, it works
  person = Person.find(1)
  last_item = model('that item')
  last_item.owner = person
  last_item.save!
end

Then /^the item description should be "([^"]*)"$/ do |description|
  last_item = model('that item')
  last_item.description.should match description
end

Then /^I should not see any of the action links$/ do
  page.should have_no_content("Edit")
  page.should have_no_content("Lost")
  page.should have_no_content("Damaged")
end
