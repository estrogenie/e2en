--!strict

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Parent.Types)
local Dependencies = require(script.Parent.Parent.Dependencies)
local Trove = Dependencies.GetTrove()
local Comm = require(script.Parent.Comm)

type Trove = Types.Trove

type ControllerDefinition = {
	Name: string,
	Dependencies: { string }?,
	[string]: any,
}

type Controller = {
	Name: string,
	Dependencies: { string }?,
	[string]: any,
}

type ServiceProxy = {
	[string]: any,
}

local Client = {}

Client.Player = Players.LocalPlayer :: Player

local controllers: { [string]: Controller } = {}
local serviceProxies: { [string]: ServiceProxy } = {}
local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

local characterTrove: Trove? = nil

local characterAddedCallbacks: { (character: Model, trove: Trove) -> () } = {}
local characterRemovingCallbacks: { (character: Model) -> () } = {}

local servicesFolder: Folder? = nil

local function GetServicesFolder(): Folder
	if servicesFolder then
		return servicesFolder
	end
	local folder = ReplicatedStorage:WaitForChild("e2enServices") :: Folder
	servicesFolder = folder
	return folder
end

local function BuildServiceProxy(serviceName: string): ServiceProxy
	local folder = GetServicesFolder():WaitForChild(serviceName) :: Folder
	local proxy: ServiceProxy = {}

	for _, child in folder:GetChildren() do
		if child:IsA("RemoteFunction") then
			if child.Name:match("_Get$") then
				continue
			end
			proxy[child.Name] = function(_self: any, ...: any)
				return child:InvokeServer(...)
			end
		elseif child:IsA("RemoteEvent") or child:IsA("UnreliableRemoteEvent") then
			local getRemote = folder:FindFirstChild(child.Name .. "_Get") :: RemoteFunction?
			if getRemote then
				-- RemoteProperty only uses RemoteEvent (not unreliable)
				proxy[child.Name] = Comm.ClientRemoteProperty.new(child :: RemoteEvent, getRemote)
			else
				-- RemoteSignal can be either RemoteEvent or UnreliableRemoteEvent
				proxy[child.Name] = Comm.ClientRemoteSignal.new(child :: RemoteEvent | UnreliableRemoteEvent)
			end
		end
	end

	return proxy
end

function Client.CreateController<T>(definition: ControllerDefinition & T): Controller & T
	assert(not started, "Cannot create controllers after framework has started")

	local name = definition.Name
	assert(name, "Controller must have a Name")
	assert(not controllers[name], `Controller '{name}' already exists`)

	local controller: Controller = definition :: any
	controllers[name] = controller

	return controller :: any
end

function Client.GetController(controllerName: string): Controller
	assert(started, "Cannot get controllers before framework has started")
	local controller = controllers[controllerName]
	assert(controller, `Controller '{controllerName}' not found`)
	return controller
end

function Client.GetControllers(): { [string]: Controller }
	return controllers
end

function Client.AddControllers(parent: Instance): { Controller }
	local added: { Controller } = {}
	for _, child in parent:GetChildren() do
		if child:IsA("ModuleScript") then
			local controller = require(child) :: Controller
			table.insert(added, controller)
		end
	end
	return added
end

function Client.AddControllersDeep(parent: Instance): { Controller }
	local added: { Controller } = {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			local controller = require(descendant) :: Controller
			table.insert(added, controller)
		end
	end
	return added
end

function Client.AddSystems(parent: Instance): { Controller }
	local added: { Controller } = {}
	for _, systemFolder in parent:GetChildren() do
		if systemFolder:IsA("Folder") then
			local controllerModule = systemFolder:FindFirstChild("Controller")
			if controllerModule and controllerModule:IsA("ModuleScript") then
				local controller = require(controllerModule) :: Controller?
				if controller then
					table.insert(added, controller)
				end
			end
		end
	end
	return added
end

function Client.AddSystemsDeep(parent: Instance): { Controller }
	local added: { Controller } = {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA("Folder") then
			local controllerModule = descendant:FindFirstChild("Controller")
			if controllerModule and controllerModule:IsA("ModuleScript") then
				local controller = require(controllerModule) :: Controller?
				if controller then
					table.insert(added, controller)
				end
			end
		end
	end
	return added
end

function Client.GetService(serviceName: string): ServiceProxy
	assert(started, "Cannot get services before framework has started")

	local existingProxy = serviceProxies[serviceName]
	if existingProxy then
		return existingProxy
	end

	local newProxy = BuildServiceProxy(serviceName)
	serviceProxies[serviceName] = newProxy
	return newProxy
end

function Client.OnCharacterAdded(callback: (character: Model, trove: Trove) -> ())
	table.insert(characterAddedCallbacks, callback)

	local character = Client.Player.Character
	if character and characterTrove then
		task.spawn(callback, character, characterTrove)
	end
end

function Client.OnCharacterRemoving(callback: (character: Model) -> ())
	table.insert(characterRemovingCallbacks, callback)
end

function Client.GetCharacterTrove(): Trove?
	return characterTrove
end

function Client.GetCharacter(): Model?
	return Client.Player.Character
end

local function HandleCharacterAdded(character: Model)
	characterTrove = Trove.new()

	for _, callback in characterAddedCallbacks do
		task.spawn(callback, character, characterTrove :: Trove)
	end
end

local function HandleCharacterRemoving(character: Model)
	for _, callback in characterRemovingCallbacks do
		task.spawn(callback, character)
	end

	if characterTrove then
		characterTrove:Clean()
		characterTrove = nil
	end
end

local function SetupCharacterLifecycle()
	Client.Player.CharacterAdded:Connect(HandleCharacterAdded)
	Client.Player.CharacterRemoving:Connect(HandleCharacterRemoving)

	if Client.Player.Character then
		HandleCharacterAdded(Client.Player.Character)
	end
end

local function TopologicalSort(): { Controller }
	local sorted: { Controller } = {}
	local visited: { [string]: boolean } = {}
	local visiting: { [string]: boolean } = {}

	local function visit(controllerName: string)
		if visited[controllerName] then
			return
		end
		if visiting[controllerName] then
			error(`Circular dependency detected involving '{controllerName}'`)
		end

		local controller = controllers[controllerName]
		if not controller then
			error(`Dependency '{controllerName}' not found`)
		end

		visiting[controllerName] = true

		if controller.Dependencies then
			for _, depName in controller.Dependencies do
				visit(depName)
			end
		end

		visiting[controllerName] = nil
		visited[controllerName] = true
		table.insert(sorted, controller)
	end

	for name in controllers do
		visit(name)
	end

	return sorted
end

local function CollectPreloadableAssets(folder: Instance): { Instance }
	local assets: { Instance } = {}

	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("Animation")
			or descendant:IsA("Sound")
			or descendant:IsA("Decal")
			or descendant:IsA("Texture")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
		then
			table.insert(assets, descendant)
		end
	end

	return assets
end

local function PreloadCommonAssets()
	local root = script.Parent.Parent
	local common = root:FindFirstChild("Shared")
	if not common then
		return
	end
	common = common:FindFirstChild("common")
	if not common then
		return
	end

	local assets = CollectPreloadableAssets(common)
	if #assets > 0 then
		ContentProvider:PreloadAsync(assets)
	end
end

function Client.Start(): ()
	assert(not started, "Framework has already started")
	assert(RunService:IsClient(), "Client.Start can only be called on the client")

	started = true

	PreloadCommonAssets()

	GetServicesFolder()

	local sortedControllers = TopologicalSort()

	for _, controller in sortedControllers do
		if controller.Init then
			controller:Init()
		end
	end

	SetupCharacterLifecycle()

	for _, controller in sortedControllers do
		if controller.Start then
			task.spawn(controller.Start, controller)
		end
	end

	startedComplete = true
	onStartedComplete:Fire()
	onStartedComplete:Destroy()
end

function Client.OnStart(): ()
	if startedComplete then
		return
	end
	onStartedComplete.Event:Wait()
end

function Client.IsStarted(): boolean
	return startedComplete
end

return Client
