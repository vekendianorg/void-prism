local Loader = {}

local Prism
local Json
local Crypto
local Paths

function Loader.init(core)
    Prism = core
    Json = core.Json
    Crypto = core.Crypto
    Paths = core.Paths
end

function Loader.readIndex()
    
end

return Loader