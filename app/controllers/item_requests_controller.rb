class ItemRequestsController < ApplicationController
  before_filter :authenticate_user!
  before_filter :get_item_request, :only => [ :show, :accept, :reject, :cancel, :collected, :complete ]
  before_filter :only_requester_or_gifter, :only => [ :show, :cancel, :collected, :complete ]
  before_filter :only_gifter, :only => [ :accept, :reject ]

  def new
    @item = Item.find(params[:item_id])
    @item_request = ItemRequest.new(:item => @item)
    @item_request.requester = current_user.person
    @item_request.gifter    = @item_request.item.owner

    respond_to do |format|
      format.html # new.html.erb
      format.xml  { render :xml => @item_request }
    end
  end

  def show
    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml => @item }
    end
  end
  
  def create
    @item_request           = ItemRequest.new(params[:item_request])
    @item_request.requester = current_user.person
    @item_request.gifter    = @item_request.item.owner
    @item_request.status    = ItemRequest::STATUS_REQUESTED

    respond_to do |format|
      if @item_request.save
        format.html { redirect_to(request_path(@item_request), :notice => 'Request was successfully created.') }
        format.xml  { render :xml => @item_request, :status => :created, :location => @item_request }
      else
        format.html { render :action => "new" }
        format.xml  { render :xml => @item_request.errors, :status => :unprocessable_entity }
      end
    end
  end

  def update
    render :text => "TODO update"
  end  
  
  def accept
    @item_request.accept!
    redirect_to(request_path(@item_request), :notice => I18n.t('messages.item_requests.request_accepted'))
  end
  
  def reject
    @item_request.reject!
    redirect_to(request_path(@item_request), :notice => I18n.t('messages.item_requests.request_rejected'))
  end
  
  def cancel
    @item_request.cancel!
    redirect_to(request_path(@item_request), :notice => I18n.t('messages.item_requests.request_canceled'))
  end
  
  def collected
    @item_request.collected!
    redirect_to(request_path(@item_request), :notice => I18n.t('messages.item_requests.request_collected'))
  end
  
  def complete
    @item_request.complete!
    redirect_to(request_path(@item_request), :notice => I18n.t('messages.item_requests.request_completed'))
  end
  
  private
  def get_item_request
    @item_request = ItemRequest.find(params[:id])
  end
  
  def only_requester_or_gifter
    unless @item_request.gifter?(current_user.person) || @item_request.requester?(current_user.person)
      redirect_to(root_path, :alert => I18n.t('messages.only_gifter_and_requester_can_access'))
    end    
  end
  
  def only_gifter
    unless @item_request.gifter? current_user.person
      redirect_to(request_path(@item_request), :alert => I18n.t('messages.only_gifter_can_access'))
    end
  end
  
  def only_requester
    unless @item_request.requester? current_user.person
      redirect_to(root_path, :alert => I18n.t('messages.only_requester_can_access'))
    end
  end
end
