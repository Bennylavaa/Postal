﻿local Postal = LibStub("AceAddon-3.0"):GetAddon("Postal")
local Postal_OpenAll = Postal:NewModule("OpenAll", "AceEvent-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("Postal")
Postal_OpenAll.description = L["A button that collects all attachments and coins from mail."]
Postal_OpenAll.description2 = L[ [[|cFFFFCC00*|r Simple filters are available for various mail types.
|cFFFFCC00*|r Shift-Click the Open All button to override the filters and take ALL mail.
|cFFFFCC00*|r OpenAll will never delete any mail (mail without text is auto-deleted by the game when all attached items and gold are taken).
|cFFFFCC00*|r OpenAll will skip CoD mails and mails from Blizzard.
|cFFFFCC00*|r Disable the Verbose option to stop the chat spam while opening mail.]] ]

local mailIndex, attachIndex
local origNumItems, origTotalItems
local lastItem, lastNumAttach, lastNumGold
local wait
local button
local Postal_OpenAllMenuButton
local skipFlag
local invFull, invAlmostFull
local openAllOverride
local PendingDel

-- Frame to process opening mail
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()
updateFrame:SetScript("OnShow", function(self)
	self.time = Postal.db.profile.OpenSpeed
	if invAlmostFull and self.time < 1.0 and not self.lootingMoney then
		self.time = 1.0
	end
	self.lootingMoney = nil
end)
updateFrame:SetScript("OnUpdate", function(self, elapsed)
	self.time = self.time - elapsed
	if self.time <= 0 then
		self:Hide()
		Postal_OpenAll:ProcessNext()
	end
end)
updateFrame:SetScript("OnEvent", function(self, event, ...)
	if event == "MAIL_INBOX_UPDATE" and PendingDel then
		PendingDel = false
		updateFrame:Show()
	end
end)

-- Frame to refresh the Inbox
-- I'm cheap so instead of trying to track 60 or so seconds since the
-- last CheckInbox(), I just call CheckInbox() every 10 seconds
local refreshFrame = CreateFrame("Frame", nil, MailFrame)
refreshFrame:Hide()
refreshFrame:SetScript("OnShow", function(self)
	self.time = 5
    self.mode = nil
end)
refreshFrame:SetScript("OnUpdate", function(self, elapsed)
	self.time = self.time - elapsed
	if self.time <= 0 then
		if self.mode == nil then
			self.time = 5
			Postal:Print(L["Refreshing mailbox..."])
			CheckInbox()
			local current, total = GetInboxNumItems()
			if current == 50 or current == total then
				-- If we're here, then mailbox contains a full fresh 50 or
				-- we're showing all the mail we have. Continue OpenAll in
				-- 1 second(s) to allow for other addons to do stuff.
				self.time = 1
				self.mode = 1
			end
		else
			self:Hide()
			Postal_OpenAll:OpenAll(true)
		end
	end
end)

function Postal_OpenAll:OnEnable()
	if not button then
		button = CreateFrame("Button", "PostalOpenAllButton", InboxFrame, "UIPanelButtonTemplate")
		button:SetWidth(120)
		button:SetHeight(25)
		if GetLocale() == "frFR" then
			button:SetPoint("CENTER", InboxFrame, "TOP", -32, -410)
		else
			button:SetPoint("CENTER", InboxFrame, "TOP", -22, -410)
		end
		button:SetText(L["Open All"])
		button:SetScript("OnClick", function() Postal_OpenAll:OpenAll() end)
		button:SetFrameLevel(button:GetFrameLevel() + 1)
	end
	if not Postal_OpenAllMenuButton then
		-- Create the Menu Button
		Postal_OpenAllMenuButton = CreateFrame("Button", "Postal_OpenAllMenuButton", InboxFrame);
		Postal_OpenAllMenuButton:SetWidth(30);
		Postal_OpenAllMenuButton:SetHeight(30);
		Postal_OpenAllMenuButton:SetPoint("LEFT", button, "RIGHT", -2, 0);
		Postal_OpenAllMenuButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up");
		Postal_OpenAllMenuButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Round");
		Postal_OpenAllMenuButton:SetDisabledTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Disabled");
		Postal_OpenAllMenuButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down");
		Postal_OpenAllMenuButton:SetScript("OnClick", function(self, button, down)
			if Postal_DropDownMenu.initialize ~= Postal_OpenAll.ModuleMenu then
				CloseDropDownMenus()
				Postal_DropDownMenu.initialize = Postal_OpenAll.ModuleMenu
			end
			ToggleDropDownMenu(1, nil, Postal_DropDownMenu, self:GetName(), 0, 0)
		end)
		Postal_OpenAllMenuButton:SetFrameLevel(Postal_OpenAllMenuButton:GetFrameLevel() + 1)
	end

	self:RegisterEvent("MAIL_SHOW")
	-- For enabling after a disable
	button:Show()
	Postal_OpenAllMenuButton:SetScript("OnHide", Postal_DropDownMenu.HideMenu)
	Postal_OpenAllMenuButton:Show()
end

function Postal_OpenAll:OnDisable()
	self:Reset()
	button:Hide()
	Postal_OpenAllMenuButton:SetScript("OnHide", nil)
	Postal_OpenAllMenuButton:Hide()
end

function Postal_OpenAll:MAIL_SHOW()
	self:RegisterEvent("MAIL_CLOSED", "Reset")
	self:RegisterEvent("PLAYER_LEAVING_WORLD", "Reset")
	updateFrame:RegisterEvent("MAIL_INBOX_UPDATE")
end

function Postal_OpenAll:OpenAll(isRecursive)
	refreshFrame:Hide()
	-- Get mail counts
	origNumItems, origTotalItems = GetInboxNumItems()
	mailIndex = origNumItems
	attachIndex = ATTACHMENTS_MAX_RECEIVE
	invFull = nil
	invAlmostFull = nil
	skipFlag = false
	lastItem = false
	lastNumAttach = nil
	lastNumGold = nil
	wait = false
	if not isRecursive then openAllOverride = IsShiftKeyDown() end
	if mailIndex == 0 then
		return
	end

	Postal:DisableInbox(1)
	button:SetText(L["In Progress"])

	self:RegisterEvent("UI_ERROR_MESSAGE")
	self:ProcessNext()
end

function Postal_OpenAll:ProcessNext()
	if mailIndex > 0 then
		-- Check if we need to wait for the mailbox to change
		if wait then
			local attachCount, goldCount = Postal:CountItemsAndMoney()
			if lastNumGold ~= goldCount then
				-- Process next mail, gold has been taken
				wait = false
				mailIndex = mailIndex - 1
				attachIndex = ATTACHMENTS_MAX_RECEIVE
				return self:ProcessNext() -- tail call
			elseif lastNumAttach ~= attachCount then
				-- Process next item, an attachment has been taken
				wait = false
				attachIndex = attachIndex - 1
				if lastItem then
					-- The item taken was the last item, process next mail
					lastItem = false
					mailIndex = mailIndex - 1
					attachIndex = ATTACHMENTS_MAX_RECEIVE
					return self:ProcessNext() -- tail call
				end
			else
				-- Wait longer until something in the mailbox changes
				updateFrame:Show()
				return
			end
		end

		local sender, msgSubject, msgMoney, msgCOD, _, msgItem, _, _, msgText, _, isGM = select(3, GetInboxHeaderInfo(mailIndex))

		-- Skip mail if it contains a CoD or if its from a GM
		if (msgCOD and msgCOD > 0) or (isGM) then
			skipFlag = true
			mailIndex = mailIndex - 1
			attachIndex = ATTACHMENTS_MAX_RECEIVE
			return self:ProcessNext() -- tail call
		end

		-- Filter by mail type
		local mailType = Postal:GetMailType(msgSubject)
		if mailType == "NonAHMail" then
			-- Skip player sent mail with attachments according to user options
			if not (openAllOverride or Postal.db.profile.OpenAll.Attachments) and msgItem then
				mailIndex = mailIndex - 1
				attachIndex = ATTACHMENTS_MAX_RECEIVE
				return self:ProcessNext() -- tail call
			end
		else
			-- AH mail, check if its from faction or neutral AH
			local factionEnglish, factionLocale = UnitFactionGroup("player")
			if not strfind(sender, factionLocale) then
				mailType = "Neutral"..mailType
			end
			-- Skip AH mail types according to user options
			if not (openAllOverride or Postal.db.profile.OpenAll[mailType]) then
				mailIndex = mailIndex - 1
				attachIndex = ATTACHMENTS_MAX_RECEIVE
				return self:ProcessNext() -- tail call
			end
		end

		-- Delete pending mail
		if mailType == "AHPending" and Postal.db.profile.OpenAll[mailType] then
			PendingDel = true
			DeleteInboxItem(mailIndex)
			mailIndex = mailIndex - 1
			do return end
		end

		-- Print message on next mail
		if Postal.db.profile.OpenAll.SpamChat and attachIndex == ATTACHMENTS_MAX_RECEIVE then
			if not invFull or msgMoney > 0 then
				local moneyString = msgMoney > 0 and " ["..Postal:GetMoneyString(msgMoney).."]" or ""
				Postal:Print(format("%s %d: %s%s", L["Processing Message"], mailIndex, msgSubject or "", moneyString))
			end
		end

		-- Find next attachment index backwards
		while not GetInboxItemLink(mailIndex, attachIndex) and attachIndex > 0 do
			attachIndex = attachIndex - 1
		end

		-- Check for free bag space
        if attachIndex > 0 and not invFull and Postal.db.profile.OpenAll.KeepFreeSpace>0 then
        	local free=0
        	for bag=0,NUM_BAG_SLOTS do
        		local bagFree,bagFam = GetContainerNumFreeSlots(bag)
        		if bagFam==0 then
        			free = free + bagFree
        		end
        	end
        	if free <= Postal.db.profile.OpenAll.KeepFreeSpace then
        		invFull = true
        		invAlmostFull = nil
        		Postal:Print(format(L["Not taking more items as there are now only %d regular bagslots free."], free))
        	elseif free <= Postal.db.profile.OpenAll.KeepFreeSpace + 1 then
        		invAlmostFull = true
        	end
        end

        -- If inventory is full, check if the item to be looted can stack with an existing stack
        local lootFlag = false
        if attachIndex > 0 and invFull then
        	local name, itemTexture, count, quality, canUse = GetInboxItem(mailIndex, attachIndex)
        	local link = GetInboxItemLink(mailIndex, attachIndex)
        	local itemID = strmatch(link, "item:(%d+)")
        	local stackSize = select(8, GetItemInfo(link))
        	if itemID and stackSize and GetItemCount(itemID) > 0 then
        		for bag = 0, NUM_BAG_SLOTS do
        			for slot = 1, GetContainerNumSlots(bag) do
        				local texture2, count2, locked2, quality2, readable2, lootable2, link2 = GetContainerItemInfo(bag, slot)
        				if link2 then
        					local itemID2 = strmatch(link2, "item:(%d+)")
        					if itemID == itemID2 and count + count2 <= stackSize then
        						lootFlag = true
        						break
        					end
        				end
        			end
        			if lootFlag then break end
        		end
        	end
        end

		if attachIndex > 0 and (lootFlag or not invFull) then
			-- If there's attachments, take the item
			--Postal:Print("Getting Item from Message "..mailIndex..", "..attachIndex)
			TakeInboxItem(mailIndex, attachIndex)

			lastNumAttach, lastNumGold = Postal:CountItemsAndMoney()
			wait = true
			-- Find next attachment index backwards
			local attachIndex2 = attachIndex - 1
			while not GetInboxItemLink(mailIndex, attachIndex2) and attachIndex2 > 0 do
				attachIndex2 = attachIndex2 - 1
			end
			if attachIndex2 == 0 and msgMoney == 0 then lastItem = true end

			updateFrame:Show()
		elseif msgMoney > 0 then
			-- No attachments, but there is money
			--Postal:Print("Getting Gold from Message "..mailIndex)
			TakeInboxMoney(mailIndex)

			lastNumAttach, lastNumGold = Postal:CountItemsAndMoney()
			wait = true
            updateFrame.lootingMoney = true
			updateFrame:Show()
		else
			-- Mail has no item or money, go to next mail
			mailIndex = mailIndex - 1
			attachIndex = ATTACHMENTS_MAX_RECEIVE
			return self:ProcessNext() -- tail call
		end

	else
		-- Reached the end of opening all selected mail

		-- If the numbers are different from previously
		local numItems, totalItems = GetInboxNumItems()
		if origNumItems ~= numItems or origTotalItems ~= totalItems then
			-- We only want to refresh if there's more items to show
			if (totalItems > numItems and numItems < 50) or (origTotalItems > origNumItems) then
				Postal:Print(L["Not all messages are shown, refreshing mailbox soon to continue Open All..."])
				refreshFrame:Show()
				return
			end
		end

		if IsAddOnLoaded("MrPlow") then
			if MrPlow.DoStuff then
				MrPlow:DoStuff("stack")
			elseif MrPlow.ParseInventory then -- Backwards compat
				MrPlow:ParseInventory()
			end
		end
		if skipFlag then Postal:Print(L["Some Messages May Have Been Skipped."]) end
		self:Reset()
	end
end

function Postal_OpenAll:Reset(event)
	refreshFrame:Hide()
	updateFrame:Hide()
	self:UnregisterEvent("UI_ERROR_MESSAGE")
	button:SetText(L["Open All"])
	Postal:DisableInbox()
	InboxFrame_Update()
	if event == "MAIL_CLOSED" or event == "PLAYER_LEAVING_WORLD" then
		self:UnregisterEvent("MAIL_CLOSED")
		self:UnregisterEvent("PLAYER_LEAVING_WORLD")
		updateFrame:UnregisterEvent("MAIL_INBOX_UPDATE")  -- ADD THIS LINE
	end
end

function Postal_OpenAll:UI_ERROR_MESSAGE(event, error_message)
	if error_message == ERR_INV_FULL then
		invFull = true
		wait = false
	elseif error_message == ERR_ITEM_MAX_COUNT then
		attachIndex = attachIndex - 1
		wait = false
	end
end

function Postal_OpenAll.SetKeepFreeSpace(dropdownbutton, arg1)
	Postal.db.profile.OpenAll.KeepFreeSpace = arg1
end

function Postal_OpenAll.ModuleMenu(self, level)
	if not level then return end
	local info = self.info
	wipe(info)
	info.isNotRadio = 1
	local db = Postal.db.profile.OpenAll
	
	if level == 1 + self.levelAdjust then
		info.hasArrow = 1
		info.keepShownOnClick = 1
		info.func = self.UncheckHack
		info.notCheckable = 1

		info.text = FACTION.." "..L["AH-related mail"]
		info.value = "AHMail"
		UIDropDownMenu_AddButton(info, level)

		info.text = FACTION_STANDING_LABEL4.." "..L["AH-related mail"]
		info.value = "NeutralAHMail"
		UIDropDownMenu_AddButton(info, level)

		info.text = L["Non-AH related mail"]
		info.value = "NonAHMail"
		UIDropDownMenu_AddButton(info, level)

		info.text = L["Other options"]
		info.value = "OtherOptions"
		UIDropDownMenu_AddButton(info, level)

	elseif level == 2 + self.levelAdjust then

		info.keepShownOnClick = 1
		info.func = Postal.SaveOption
		info.arg1 = "OpenAll"

		if UIDROPDOWNMENU_MENU_VALUE == "AHMail" then
			info.text = L["Open all Auction cancelled mail"]
			info.arg2 = "AHCancelled"
			info.checked = db.AHCancelled
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction expired mail"]
			info.arg2 = "AHExpired"
			info.checked = db.AHExpired
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Outbid on mail"]
			info.arg2 = "AHOutbid"
			info.checked = db.AHOutbid
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction successful mail"]
			info.arg2 = "AHSuccess"
			info.checked = db.AHSuccess
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction won mail"]
			info.arg2 = "AHWon"
			info.checked = db.AHWon
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction pending mail"]
			info.arg2 = "AHPending"
			info.checked = db.AHPending
			UIDropDownMenu_AddButton(info, level)

		elseif UIDROPDOWNMENU_MENU_VALUE == "NeutralAHMail" then
			info.text = L["Open all Auction cancelled mail"]
			info.arg2 = "NeutralAHCancelled"
			info.checked = db.NeutralAHCancelled
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction expired mail"]
			info.arg2 = "NeutralAHExpired"
			info.checked = db.NeutralAHExpired
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Outbid on mail"]
			info.arg2 = "NeutralAHOutbid"
			info.checked = db.NeutralAHOutbid
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction successful mail"]
			info.arg2 = "NeutralAHSuccess"
			info.checked = db.NeutralAHSuccess
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction won mail"]
			info.arg2 = "NeutralAHWon"
			info.checked = db.NeutralAHWon
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction pending mail"]
			info.arg2 = "NeutralAHPending"
			info.checked = db.NeutralAHPending
			UIDropDownMenu_AddButton(info, level)

		elseif UIDROPDOWNMENU_MENU_VALUE == "NonAHMail" then
			info.text = L["Open all mail with attachments"]
			info.arg2 = "Attachments"
			info.checked = db.Attachments
			UIDropDownMenu_AddButton(info, level)

		elseif UIDROPDOWNMENU_MENU_VALUE == "OtherOptions" then
			info.text = L["Keep free space"]
			info.hasArrow = 1
			info.value = "KeepFreeSpace"
			info.func = self.UncheckHack
			UIDropDownMenu_AddButton(info, level)
			local listFrame = _G["DropDownList"..level]
			self.UncheckHack(_G[listFrame:GetName().."Button"..listFrame.numButtons])

			info.text = L["Verbose mode"]
			info.hasArrow = nil
			info.value = nil
			info.func = Postal.SaveOption
			info.arg2 = "SpamChat"
			info.checked = db.SpamChat
			UIDropDownMenu_AddButton(info, level)
		end

	elseif level == 3 + self.levelAdjust then
		if UIDROPDOWNMENU_MENU_VALUE == "KeepFreeSpace" then
			local keepFree = db.KeepFreeSpace
			info.func = Postal_OpenAll.SetKeepFreeSpace
			info.isNotRadio = nil
			for _, v in ipairs(Postal.keepFreeOptions) do
				info.text = v
				info.checked = v == keepFree
				info.arg1 = v
				UIDropDownMenu_AddButton(info, level)
			end
		end
	end
end
