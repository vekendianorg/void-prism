local Builder = {}

local Prism
local Json
local Crypto
local Paths

function Builder.init(core)
    Prism = core
    Json = core.Json
    Crypto = core.Crypto
    Paths = core.Paths
end

return Builder