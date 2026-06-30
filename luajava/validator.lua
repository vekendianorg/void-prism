local Validator = {}

local Prism
local Json
local Crypto
local Paths

function Validator.init(core)
    Prism = core
    Json = core.Json
    Crypto = core.Crypto
    Paths = core.Paths
end

return Validator