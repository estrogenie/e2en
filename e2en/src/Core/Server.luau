--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Parent.Types)
local Dependencies = require(script.Parent.Parent.Dependencies)
local Trove = Dependencies.GetTrove()
local Comm = require(script.Parent.Comm)

type Trove = Types.Trove
type InboundMiddleware = Types.InboundMiddleware
type OutboundMiddleware = Types.OutboundMiddleware

type ServiceDefinition = {
	Name: string,
	Client: { [string]: any }?,
	Dependencies: { string }?,
	[string]: any,
}

type Service = {
	Name: string,
	Client: { [string]: any },
	Dependencies: { string }?,
	_folder: Folder?,
	[string]: any,
}

local Server = {}

local services: { [string]: Service } = {}
local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

local inboundMiddleware: { InboundMiddleware } = {}
local outboundMiddleware: { OutboundMiddleware } = {}

local playerTroves: { [Player]: Trove } = {}
local characterTroves: { [Player]: Trove } = {}

local playerAddedCallbacks: { (player: Player, trove: Trove) -> () } = {}
local playerRemovingCallbacks: { (player: Player) -> () } = {}
local characterAddedCallbacks: { (player: Player, character: Model, trove: Trove) -> () } = {}
local characterRemovingCallbacks: { (player: Player, character: Model) -> () } = {}

local servicesFolder: Folder

local function RunInboundMiddleware(player: Player, serviceName: string, methodName: string, args: { any }): (boolean, { any })
	local currentArgs = args
	for _, middleware in inboundMiddleware do
		local shouldContinue, newArgs = middleware(player, serviceName, methodName, currentArgs)
		if not shouldContinue then
			return false, {}
		end
		currentArgs = newArgs
	end
	return true, currentArgs
end

local function SetupServicesFolder()
	servicesFolder = Instance.new("Folder")
	servicesFolder.Name = "e2enServices"
end

local function ExposeServicesToClients()
	servicesFolder.Parent = ReplicatedStorage
end

local function ReplicateClientFramework()
	-- Clone the entire e2en framework to ReplicatedStorage
	local e2enRoot = script.Parent.Parent
	local e2enClient = e2enRoot:Clone()
	e2enClient.Name = "e2en"

	-- Remove server-only modules
	local serverModule = e2enClient:FindFirstChild("Core") and e2enClient.Core:FindFirstChild("Server")
	if serverModule then
		serverModule:Destroy()
	end

	-- Remove all Service.luau files from Systems (server-only code)
	local systemsFolder = e2enClient:FindFirstChild("Systems")
	if systemsFolder then
		for _, descendant in systemsFolder:GetDescendants() do
			if descendant:IsA("ModuleScript") and descendant.Name == "Service" then
				descendant:Destroy()
			end
		end
	end

	e2enClient.Parent = ReplicatedStorage
end

local function BindClientMethod(service: Service, methodName: string, method: (any, Player, ...any) -> ...any)
	local remoteFunction = Instance.new("RemoteFunction")
	remoteFunction.Name = methodName
	remoteFunction.Parent = service._folder

	remoteFunction.OnServerInvoke = function(player: Player, ...: any)
		local args = { ... }
		local shouldContinue, processedArgs = RunInboundMiddleware(player, service.Name, methodName, args)
		if not shouldContinue then
			return nil
		end
		local result = { method(service.Client, player, table.unpack(processedArgs)) }
		return table.unpack(result)
	end
end

local function ProcessClientTable(service: Service)
	local clientTable = service.Client
	if not clientTable then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = service.Name
	folder.Parent = servicesFolder
	service._folder = folder

	clientTable.Server = service

	for key, value in clientTable do
		if key == "Server" then
			continue
		end

		if type(value) == "function" then
			BindClientMethod(service, key, value)
		elseif Comm.IsSignalMarker(value) then
			local signal = Comm.RemoteSignal.new(folder, key, false, service.Name, outboundMiddleware)
			clientTable[key] = signal
		elseif Comm.IsUnreliableSignalMarker(value) then
			local signal = Comm.RemoteSignal.new(folder, key, true, service.Name, outboundMiddleware)
			clientTable[key] = signal
		elseif Comm.IsPropertyMarker(value) then
			local property = Comm.RemoteProperty.new(folder, key, value._initialValue, service.Name, outboundMiddleware)
			clientTable[key] = property
		end
	end
end

function Server.CreateService<T>(definition: ServiceDefinition & T): Service & T
	assert(not started, "Cannot create services after framework has started")

	local name = definition.Name
	assert(name, "Service must have a Name")
	assert(not services[name], `Service '{name}' already exists`)

	local service: Service = definition :: any
	service.Client = service.Client or {}

	services[name] = service

	return service :: any
end

function Server.GetService(serviceName: string): Service
	local service = services[serviceName]
	assert(service, `Service '{serviceName}' not found`)
	return service
end

function Server.GetServices(): { [string]: Service }
	return services
end

function Server.AddServices(parent: Instance): { Service }
	local added: { Service } = {}
	for _, child in parent:GetChildren() do
		if child:IsA("ModuleScript") then
			local service = require(child) :: Service
			table.insert(added, service)
		end
	end
	return added
end

function Server.AddServicesDeep(parent: Instance): { Service }
	local added: { Service } = {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			local service = require(descendant) :: Service
			table.insert(added, service)
		end
	end
	return added
end

function Server.AddSystems(parent: Instance): { Service }
	local added: { Service } = {}
	for _, systemFolder in parent:GetChildren() do
		if systemFolder:IsA("Folder") then
			local serviceModule = systemFolder:FindFirstChild("Service")
			if serviceModule and serviceModule:IsA("ModuleScript") then
				local service = require(serviceModule) :: Service?
				if service then
					table.insert(added, service)
				end
			end
		end
	end
	return added
end

function Server.AddSystemsDeep(parent: Instance): { Service }
	local added: { Service } = {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA("Folder") then
			local serviceModule = descendant:FindFirstChild("Service")
			if serviceModule and serviceModule:IsA("ModuleScript") then
				local service = require(serviceModule) :: Service?
				if service then
					table.insert(added, service)
				end
			end
		end
	end
	return added
end

function Server.CreateSignal()
	return Comm.CreateSignalMarker()
end

function Server.CreateUnreliableSignal()
	return Comm.CreateUnreliableSignalMarker()
end

function Server.CreateProperty<T>(initialValue: T)
	return Comm.CreatePropertyMarker(initialValue)
end

function Server.OnPlayerAdded(callback: (player: Player, trove: Trove) -> ())
	table.insert(playerAddedCallbacks, callback)

	for _, player in Players:GetPlayers() do
		local trove = playerTroves[player]
		if trove then
			task.spawn(callback, player, trove)
		end
	end
end

function Server.OnPlayerRemoving(callback: (player: Player) -> ())
	table.insert(playerRemovingCallbacks, callback)
end

function Server.OnCharacterAdded(callback: (player: Player, character: Model, trove: Trove) -> ())
	table.insert(characterAddedCallbacks, callback)

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local trove = characterTroves[player]
		if character and trove then
			task.spawn(callback, player, character, trove)
		end
	end
end

function Server.OnCharacterRemoving(callback: (player: Player, character: Model) -> ())
	table.insert(characterRemovingCallbacks, callback)
end

function Server.GetPlayerTrove(player: Player): Trove?
	return playerTroves[player]
end

function Server.GetCharacterTrove(player: Player): Trove?
	return characterTroves[player]
end

local function HandleCharacterAdded(player: Player, character: Model)
	local trove = Trove.new()
	characterTroves[player] = trove

	for _, callback in characterAddedCallbacks do
		task.spawn(callback, player, character, trove)
	end
end

local function HandleCharacterRemoving(player: Player, character: Model)
	for _, callback in characterRemovingCallbacks do
		task.spawn(callback, player, character)
	end

	local trove = characterTroves[player]
	if trove then
		trove:Clean()
		characterTroves[player] = nil
	end
end

local function HandlePlayerAdded(player: Player)
	local trove = Trove.new()
	playerTroves[player] = trove

	trove:Add(player.CharacterAdded:Connect(function(character)
		HandleCharacterAdded(player, character)
	end))

	trove:Add(player.CharacterRemoving:Connect(function(character)
		HandleCharacterRemoving(player, character)
	end))

	if player.Character then
		HandleCharacterAdded(player, player.Character)
	end

	for _, callback in playerAddedCallbacks do
		task.spawn(callback, player, trove)
	end
end

local function HandlePlayerRemoving(player: Player)
	local characterTrove = characterTroves[player]
	if characterTrove then
		characterTrove:Clean()
		characterTroves[player] = nil
	end

	for _, callback in playerRemovingCallbacks do
		task.spawn(callback, player)
	end

	local trove = playerTroves[player]
	if trove then
		trove:Clean()
		playerTroves[player] = nil
	end
end

local function SetupPlayerLifecycle()
	Players.PlayerAdded:Connect(HandlePlayerAdded)
	Players.PlayerRemoving:Connect(HandlePlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(HandlePlayerAdded, player)
	end
end

local function TopologicalSort(): { Service }
	local sorted: { Service } = {}
	local visited: { [string]: boolean } = {}
	local visiting: { [string]: boolean } = {}

	local function visit(serviceName: string)
		if visited[serviceName] then
			return
		end
		if visiting[serviceName] then
			error(`Circular dependency detected involving '{serviceName}'`)
		end

		local service = services[serviceName]
		if not service then
			error(`Dependency '{serviceName}' not found`)
		end

		visiting[serviceName] = true

		if service.Dependencies then
			for _, depName in service.Dependencies do
				visit(depName)
			end
		end

		visiting[serviceName] = nil
		visited[serviceName] = true
		table.insert(sorted, service)
	end

	for name in services do
		visit(name)
	end

	return sorted
end

function Server.Start(config: Types.RunConfig?): ()
	assert(not started, "Framework has already started")
	assert(RunService:IsServer(), "Server.Start can only be called on the server")

	started = true

	if config and config.Middleware then
		if config.Middleware.Inbound then
			inboundMiddleware = config.Middleware.Inbound
		end
		if config.Middleware.Outbound then
			outboundMiddleware = config.Middleware.Outbound
		end
	end

	ReplicateClientFramework()

	SetupServicesFolder()

	local sortedServices = TopologicalSort()

	for _, service in sortedServices do
		ProcessClientTable(service)
	end

	for _, service in sortedServices do
		if service.Init then
			service:Init()
		end
	end

	SetupPlayerLifecycle()

	for _, service in sortedServices do
		if service.Start then
			task.spawn(service.Start, service)
		end
	end

	ExposeServicesToClients()

	startedComplete = true
	onStartedComplete:Fire()
	onStartedComplete:Destroy()
end

function Server.OnStart(): ()
	if startedComplete then
		return
	end
	onStartedComplete.Event:Wait()
end

function Server.IsStarted(): boolean
	return startedComplete
end

return Server
