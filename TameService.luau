-- Used in https://www.roblox.com/games/126996552693338/Catch-A-Pet
--[==[

	[TameService.luau]:
		Handle Catch A Pet's taming mechanic

	[Author(s)]:
		- Vyon (https://github.com/Vyon)

--]==]

-- Services:
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Modules:
local Analytics = require(script.Parent.Analytics)
local PetManager = require(script.Parent.PetManager)
local UserService = require(script.Parent.UserService)
local QuestService = require(script.Parent.QuestService)
local TutorialService = require(script.Parent.TutorialService)
local LeaderboardService = require(script.Parent.LeaderboardService)

local Tools = require(ServerStorage.Modules.Tools)
local ObjectUtil = require(ServerStorage.Modules.ObjectUtil)

local RateLimit = require(ServerStorage.Middleware.RateLimit)

local Notif = require(ReplicatedStorage.Shared.Notif)
local Network = require(ReplicatedStorage.Shared.Network)
local Database = require(ReplicatedStorage.Shared.Database)

local Lagoon = require(ReplicatedStorage.Packages.Lagoon) -- This was made by me btw :)

-- Types:
export type TameService = {
	-- Fields --
	Active: { [Player]: PetManager.Pet },

	-- Methods --
	Begin: (self: TameService, Player: Player, PetObject: PetManager.Pet) -> (),
	Catch: (self: TameService, Player: Player, UId: number) -> (),
	Pull: (self: TameService, Player: Player) -> (),
	Success: (self: TameService, Player: Player, PetObject: PetManager.Pet) -> (),
	Failed: (self: TameService, Player: Player, PetObject: PetManager.Pet) -> (),

	__CreateCatchThread: (self: TameService, Player: Player, PetObject: PetManager.Pet) -> (),

	-- Initializers --
	Init: (self: TameService) -> (),
} & typeof(Lagoon.Traits.Logger)

-- Constants:
local ENCOUNTER_DURATION = 15
local MAX_ENCOUNTER_DISTANCE = 30

local UPDATE_RATE = 0.15
local PULL_COOLDOWN = 0.1

local DECAY_PERCENT = 1
local WEAKENING_MULTI = 0.6

-- Main Module:
local TameService = {
	-- Fields --
	Active = {},

	LogOptions = {
		Debug = false,
	},
} :: TameService

-- Public Methods --
function TameService:Begin(Player: Player, PetObject: PetManager.Pet)
	local User = UserService.Users[Player]

	if not User then
		self:Log("Debug/Warn", `{Player.Name} does not have an associated User object`)

		return
	end

	local Character = Player.Character

	if not Character or not Character:IsDescendantOf(workspace) then
		self:Log("Debug/Warn", `{Player.Name} does not have a valid character`)

		return
	end

	local PetInfo = Database.Pets[PetObject.Id]

	if not PetInfo then
		self:Log("Debug/Warn", `Pet with id '{PetObject.Id}' not found`)

		return
	end

	if self.Active[Player] then
		self:Log("Debug/Warn", `{Player.Name} is already in an encounter`)

		return
	end

	-- Is within a slot?
	if PetObject.Props.Parent ~= workspace.Active then
		self:Log("Debug/Warn", `{Player.Name} attempted to tame a pet in a slot`)

		return
	end

	-- Is Owned?
	if PetObject.Owner then
		self:Log("Debug/Warn", `{Player.Name} attempted to tame a pet owned by {PetObject.Owner.Name}`)

		return
	end

	-- Is already being challenged?
	if PetObject.Props.ChallengedBy then
		self:Log("Debug/Warn", `{PetObject.UId} is already being challenged`)

		return
	end

	-- Is in tutorial and did not interact with a bunny:
	if Player:GetAttribute("Tutorial") and PetObject.Id ~= "Bunny" then
		self:Log("Debug/Warn", `{Player.Name} attempted to tame {PetObject.Id} #{PetObject.UId} while in the tutorial`)

		return
	end

	self:Log("Debug/Info", `{Player.Name} is beginning encounter with {PetObject.Id} (#{PetObject.UId})`)

	TutorialService.OnAction:Fire(Player, "Encounter", PetObject)

	-- Cache the pet the player is actively engaged with:
	self.Active[Player] = PetObject

	self:__CreateCatchThread(Player, PetObject)
end

function TameService:Catch(Player: Player, UId: number)
	if self.Active[Player] then
		self:Log("Debug/Warn", `{Player.Name} is already in an encounter`)

		return
	end

	local Character = Player.Character

	if not Character or not Character:IsDescendantOf(workspace) then
		self:Log("Debug/Warn", `{Player.Name} does not have a valid character`)

		return
	end

	local PetObject = PetManager.Cache[UId] :: PetManager.Pet?

	if not PetObject or not PetObject.Alive then
		self:Log("Debug/Warn", `{Player.Name} provided pet with UId #{UId} that doesn't exist`)

		return
	end

	if PetObject.Owner ~= nil then
		self:Log("Debug/Warn", `{Player.Name} provided pet with UId #{UId} is not a road pet`)

		return
	end

	if not ObjectUtil.IsNear(Character:GetPivot(), PetObject.Props.Location, MAX_ENCOUNTER_DISTANCE) then
		self:Log("Debug/Warn", `{Player.Name} is not near pet '{PetObject.Id}' (#{UId})`)

		return
	end

	if Player:FindFirstChild("Leading") then
		self:Log("Debug/Warn", `{Player.Name} has a pet lassoed`)

		return
	end

	local LassoLevel = (Player:GetAttribute("Lasso") :: number?) or 1

	if LassoLevel < PetObject.Info.Index then
		self:Log("Debug/Warn", `{Player.Name}'s lasso is level {LassoLevel}, the requirement is {PetObject.Info.Index}`)

		return
	end

	self:Begin(Player, PetObject)
end

function TameService:Pull(Player: Player)
	self:Log("Debug/Info", `{Player.Name} is pulling the lasso`)

	local User = UserService.Users[Player]

	if not User then
		self:Log("Debug/Warn", `{Player.Name} does not have an associated User object`)

		return
	end

	local PetObject = self.Active[Player]

	if not PetObject or not PetObject.Alive then
		self:Log("Debug/Warn", `The pet {Player.Name} engaged with is no longer alive or has been disengaged`)

		return
	end

	local LassoInfo = Database.Lassos[User.Data.Lasso]

	if not LassoInfo then
		return
	end

	local PetInfo = Database.Pets[PetObject.Id]

	if not PetInfo then
		self:Log("Debug/Warn", `Info for pet with id '{PetObject.Id}' not found`)

		return
	end

	-- Determine the amount of progress the player may or may not have made:
	local Diff = (LassoInfo.Strength - PetInfo.Strength) * WEAKENING_MULTI

	-- Update & replicate the pull percentage:
	PetObject:Set("PullPercent", PetObject.Props.PullPercent + (math.max(Diff, 1)))

	return true
end

function TameService:Success(Player: Player, PetObject: PetManager.Pet)
	local User = UserService.Users[Player]

	if not User then
		self:Log("Debug/Warn", `{Player.Name} does not have an associated User object`)

		return
	end

	local PetInfo = Database.Pets[PetObject.Id]

	if not PetInfo then
		self:Log("Debug/Warn", `Pet with id '{PetObject.Id}' not found`)

		return
	end

	local Mutations = PetObject.Props.Mutations:split(",")

	-- Trigger quest category updates:
	QuestService:HandleUpdate(Player, "CatchPet", PetInfo.Rarity)

	-- Does the caught pet have an innate mutation?
	if Mutations[1] ~= "None" then
		QuestService:HandleUpdate(Player, "CatchMutatedPet", Mutations[1])
	end

	-- Update the pet's index state:
	User:UnlockPet(Mutations[1], PetObject.Id)

	-- Ensure the player's character exists:
	if not Player.Character then
		Player.CharacterAdded:Wait()
	end

	do -- Report to funnel:
		local DidReport, Error = pcall(function()
			Analytics:Funnel(
				Player,
				"Overworld Pets",
				Analytics:GetStepIndex("Overworld Pets", `Level {PetObject.Info.Index}`)
			)
		end)

		if not DidReport then
			warn(`[TameService:Success] Failed to report analytics: {Error}`)
		else
			self:Log("Debug/Info", `Reported pet catch to funnel`)
		end
	end

	do -- Update how many pets the player has caught:
		local DidUpdate, Error = pcall(function()
			-- Update the total amount of pets caught:
			User.Data.Stats.PetsCaught += 1
			User.Leaderstats.Caught.Value = User.Data.Stats.PetsCaught

			-- Update the amount of pets the player has caught on the global leaderboard:
			LeaderboardService:Set("Catches", tostring(Player.UserId), User.Data.Stats.PetsCaught)
		end)

		if not DidUpdate then
			self:Log("Warn", `[TameService:Success] Failed to update amount of caught pets: {Error}`)
		else
			self:Log("Debug/Info", `Updated {Player.Name}'s leaderboard catch amount`)
		end
	end

	local Id = PetObject.Id
	local ActiveMutations = PetObject.Props.Mutations

	-- Cleanup pet before pet tool is given:
	PetManager:Destroy(PetObject.UId)

	-- Give pet to the player:
	Tools.Pet(Player, {
		Id = Id,
		Exp = "0",
		Mutations = ActiveMutations or "None,None",
	}, "Character")

	-- Send notification to the player:
	Notif.Success(Player, `You caught a {PetInfo.Name}!`)
end

function TameService:Failed(Player: Player, PetObject: PetManager.Pet)
	local PetInfo = PetObject.Info

	-- Has the pet's info been derefenced? (Pet destroyed)
	if not PetInfo then
		self:Log("Debug/Warn", `Pet with id '{PetObject.Id}' not found`)

		return
	end

	-- Send notification to the player:
	Notif.Error(Player, `{PetInfo.Name} got away...`, {
		Sound = "Released",
	})

	-- Reset pet state:
	PetObject:Set("Speed", PetObject.Props.Speed)
	PetObject:Set("PullPercent", 0)
	PetObject.Props.ChallengedBy = nil
end

-- Private Methods --
function TameService:__CreateCatchThread(Player: Player, PetObject: PetManager.Pet)
	local User = UserService.Users[Player]

	if not User then
		self:Log("Debug/Warn", `{Player.Name} does not have an associated User object`)

		return
	end

	if not PetObject.Alive then
		self:Log("Debug/Warn", `Pet #{PetObject.UId} has been cleaned up`)

		return
	end

	local PetInfo = Database.Pets[PetObject.Id]

	if not PetInfo then
		self:Log("Debug/Warn", `Pet with id '{PetObject.Id}' not found`)

		return
	end

	local Character = Player.Character

	if not Character or not Character:IsDescendantOf(workspace) then
		self:Log("Debug/Warn", `{Player.Name} does not have a valid character`)

		return
	end

	TutorialService.OnAction:Fire(Player, "Tamed", PetObject)

	-- Replicate the uid of the target pet & when the encounter ends:
	local EndsAt = workspace:GetServerTimeNow() + ENCOUNTER_DURATION

	Network:FireClient("TameState", Player, PetObject.UId, EndsAt // 1)

	-- Create thread for when the counter should expire:
	local CancelThread = task.delay(ENCOUNTER_DURATION, function()
		PetObject:Set("PullPercent", 0)
	end)

	-- Set base state:
	PetObject:Set("Speed", 0)
	PetObject:Set("PullPercent", 50)
	PetObject.Props.ChallengedBy = Player

	-- Start main thread:
	task.defer(function()
		local DidCatch = false

		local Props = PetObject.Props or {
			PullPercent = 50,
		}

		local PullPercent = Props.PullPercent

		-- While the pet is alive and the player has not failed to catch the pet:
		while PetObject.Alive and PullPercent > 0 do
			-- Use floor div to ensure pull percent is restricted to ints only
			PullPercent = Props.PullPercent // 1

			-- Has the player caught the pet?
			if PullPercent >= 100 then
				DidCatch = true

				break
			end

			-- The minimum pull percentage the pet can reach:
			local Min = 0

			-- Use GetAttribute to determine if the player is in the tutorial
			if Player:GetAttribute("Tutorial") then
				-- Prevent the encounter from ending so the player
				-- may continue attempting to catch the pet with their
				-- remaining time
				Min = 1
			end

			-- Display the encounter's percentage in the console:
			self:Log("Debug/Info", `{PullPercent}%`)

			-- Update and replicate the PullPercent:
			PetObject:Set("PullPercent", math.clamp(PullPercent - DECAY_PERCENT, Min, 100))

			-- Yield the current thread for UPDATE_RATE seconds:
			task.wait(UPDATE_RATE)
		end

		-- Finish / cleanup stuff:
		pcall(task.cancel, CancelThread) --> Idk if this can error and I don't want to find out
		self.Active[Player] = nil

		self:Log(
			"Debug/Info",
			`{Player.Name}'s encounter with {PetObject.Id} (#{PetObject.UId}) has {DidCatch and "succeeded!" or "failed."}`
		)

		-- Call encounter status methods:
		if DidCatch then
			self:Success(Player, PetObject)
		else
			self:Failed(Player, PetObject)
		end

		-- Fire the TameState Remote with the pet uid set to nil so,
		-- the encounter state will be reset on the client
		Network:FireClient("TameState", Player, nil)
	end)
end

-- Initializers --
function TameService:Init()
	do -- Remotes:
		-- Events:
		Network:CreateEvent("Catch")
		Network:CreateEvent("TameState")

		-- Bindings:
		Network:CreateFunction("PullLasso")

		-- Middleware:
		Network:AddMiddleware("PullLasso", RateLimit(PULL_COOLDOWN))

		-- Connections:
		Network:Connect("Catch", function(Player: Player, UId: number)
			self:Catch(Player, UId)
		end)

		-- Bindings:
		Network:Bind("PullLasso", function(Player: Player)
			return self:Pull(Player)
		end)
	end
end

return Lagoon.Wrap(TameService):ApplyTrait(Lagoon.Traits.Logger) -- Integrate TameService into the Lagoon environment and apply the Logger trait
