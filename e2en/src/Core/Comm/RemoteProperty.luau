--!strict

local Players = game:GetService("Players")

local Types = require(script.Parent.Parent.Parent.Types)
local Dependencies = require(script.Parent.Parent.Parent.Dependencies)
local Signal = Dependencies.GetSignal()

type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

type OutboundMiddleware = Types.OutboundMiddleware

export type RemoteProperty<T> = {
	Get: (self: RemoteProperty<T>) -> T,
	Set: (self: RemoteProperty<T>, value: T) -> (),
	SetTop: (self: RemoteProperty<T>, value: T) -> (),
	SetFor: (self: RemoteProperty<T>, player: Player, value: T) -> (),
	SetForList: (self: RemoteProperty<T>, players: { Player }, value: T) -> (),
	SetFilter: (self: RemoteProperty<T>, predicate: (Player) -> boolean, value: T) -> (),
	ClearFor: (self: RemoteProperty<T>, player: Player) -> (),
	ClearForList: (self: RemoteProperty<T>, players: { Player }) -> (),
	GetFor: (self: RemoteProperty<T>, player: Player) -> T,
	Observe: (self: RemoteProperty<T>, callback: (value: T) -> ()) -> Connection,
	Destroy: (self: RemoteProperty<T>) -> (),
}

type RemotePropertyInternal<T> = {
	_remote: RemoteEvent,
	_getRemote: RemoteFunction,
	_topValue: T,
	_perPlayer: { [Player]: T },
	_perPlayerSet: { [Player]: boolean },
	_signal: any,
	_playerRemovingConnection: RBXScriptConnection,
	_serviceName: string,
	_propertyName: string,
	_middleware: { OutboundMiddleware },
}

local RemoteProperty = {}
RemoteProperty.__index = RemoteProperty

local function RunOutboundMiddleware(
	middleware: { OutboundMiddleware },
	player: Player?,
	serviceName: string,
	propertyName: string,
	args: { any }
): (boolean, { any })
	local currentArgs = args
	for _, mw in middleware do
		local shouldContinue, newArgs = mw(player, serviceName, propertyName, currentArgs)
		if not shouldContinue then
			return false, {}
		end
		currentArgs = newArgs
	end
	return true, currentArgs
end

function RemoteProperty.new<T>(
	parent: Instance,
	name: string,
	initialValue: T,
	serviceName: string?,
	middleware: { OutboundMiddleware }?
): RemoteProperty<T>
	local remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = name
	remoteEvent.Parent = parent

	local remoteFunction = Instance.new("RemoteFunction")
	remoteFunction.Name = name .. "_Get"
	remoteFunction.Parent = parent

	local self = setmetatable({
		_remote = remoteEvent,
		_getRemote = remoteFunction,
		_topValue = initialValue,
		_perPlayer = {} :: { [Player]: T },
		_perPlayerSet = {} :: { [Player]: boolean },
		_signal = Signal.new(),
		_playerRemovingConnection = nil :: RBXScriptConnection?,
		_serviceName = serviceName or "",
		_propertyName = name,
		_middleware = middleware or {},
	}, RemoteProperty)

	remoteFunction.OnServerInvoke = function(player: Player)
		return (self :: any):GetFor(player)
	end

	self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		(self :: any)._perPlayer[player] = nil
		(self :: any)._perPlayerSet[player] = nil
	end)

	return self :: any
end

function RemoteProperty.Get<T>(self: RemotePropertyInternal<T>): T
	return self._topValue
end

function RemoteProperty.Set<T>(self: RemotePropertyInternal<T>, value: T)
	self._topValue = value
	table.clear(self._perPlayer)
	table.clear(self._perPlayerSet)
	local shouldContinue, processedArgs = RunOutboundMiddleware(self._middleware, nil, self._serviceName, self._propertyName, { value })
	if shouldContinue and #processedArgs > 0 then
		self._remote:FireAllClients(processedArgs[1])
	end
	self._signal:Fire(value)
end

function RemoteProperty.SetTop<T>(self: RemotePropertyInternal<T>, value: T)
	self._topValue = value
	for _, player in Players:GetPlayers() do
		if not self._perPlayerSet[player] then
			local shouldContinue, processedArgs = RunOutboundMiddleware(self._middleware, player, self._serviceName, self._propertyName, { value })
			if shouldContinue and #processedArgs > 0 then
				self._remote:FireClient(player, processedArgs[1])
			end
		end
	end
	self._signal:Fire(value)
end

function RemoteProperty.SetFor<T>(self: RemotePropertyInternal<T>, player: Player, value: T)
	self._perPlayer[player] = value
	self._perPlayerSet[player] = true
	local shouldContinue, processedArgs = RunOutboundMiddleware(self._middleware, player, self._serviceName, self._propertyName, { value })
	if shouldContinue and #processedArgs > 0 then
		self._remote:FireClient(player, processedArgs[1])
	end
end

function RemoteProperty.SetForList<T>(self: RemotePropertyInternal<T>, players: { Player }, value: T)
	for _, player in players do
		(self :: any):SetFor(player, value)
	end
end

function RemoteProperty.SetFilter<T>(self: RemotePropertyInternal<T>, predicate: (Player) -> boolean, value: T)
	for _, player in Players:GetPlayers() do
		if predicate(player) then
			(self :: any):SetFor(player, value)
		end
	end
end

function RemoteProperty.ClearFor<T>(self: RemotePropertyInternal<T>, player: Player)
	self._perPlayer[player] = nil
	self._perPlayerSet[player] = nil
	local shouldContinue, processedArgs = RunOutboundMiddleware(self._middleware, player, self._serviceName, self._propertyName, { self._topValue })
	if shouldContinue and #processedArgs > 0 then
		self._remote:FireClient(player, processedArgs[1])
	end
end

function RemoteProperty.ClearForList<T>(self: RemotePropertyInternal<T>, players: { Player })
	for _, player in players do
		(self :: any):ClearFor(player)
	end
end

function RemoteProperty.GetFor<T>(self: RemotePropertyInternal<T>, player: Player): T
	if self._perPlayerSet[player] then
		return self._perPlayer[player]
	end
	return self._topValue
end

function RemoteProperty.Observe<T>(self: RemotePropertyInternal<T>, callback: (value: T) -> ()): Connection
	callback(self._topValue)
	return self._signal:Connect(callback)
end

function RemoteProperty.Destroy<T>(self: RemotePropertyInternal<T>)
	self._playerRemovingConnection:Disconnect()
	self._remote:Destroy()
	self._getRemote:Destroy()
	self._signal:Destroy()
end

return RemoteProperty
