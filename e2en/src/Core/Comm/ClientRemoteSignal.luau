--!strict

type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type ClientRemoteSignal<T...> = {
	Fire: (self: ClientRemoteSignal<T...>, T...) -> (),
	Connect: (self: ClientRemoteSignal<T...>, callback: (T...) -> ()) -> Connection,
	Destroy: (self: ClientRemoteSignal<T...>) -> (),
	_remote: RemoteEvent | UnreliableRemoteEvent,
}

local ClientRemoteSignal = {}
ClientRemoteSignal.__index = ClientRemoteSignal

function ClientRemoteSignal.new<T...>(remoteEvent: RemoteEvent | UnreliableRemoteEvent): ClientRemoteSignal<T...>
	local self = setmetatable({
		_remote = remoteEvent,
	}, ClientRemoteSignal)

	return self :: any
end

function ClientRemoteSignal.Fire<T...>(self: ClientRemoteSignal<T...>, ...: T...)
	(self._remote :: RemoteEvent):FireServer(...)
end

function ClientRemoteSignal.Connect<T...>(self: ClientRemoteSignal<T...>, callback: (T...) -> ()): Connection
	return (self._remote :: RemoteEvent).OnClientEvent:Connect(callback) :: any
end

function ClientRemoteSignal.Destroy<T...>(_self: ClientRemoteSignal<T...>)
	-- Client doesn't own the remote, nothing to destroy
end

return ClientRemoteSignal
