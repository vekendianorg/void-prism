-- Prism
local Prism = {}

-- External Lua imports
Prism.Json = require("json.lua")

-- Java imports
Prism.Crypto = luajava.bindClass("org.vekendian.Crypto")

-- Paths
Prism.Paths = {}
Prism.Paths.CONTENT = "/data/user/0/com.waxmoon.ma.gp/rootfs/data/user/0/com.fingersoft.hcr2/files/content_cache/"
Prism.Paths.PACKAGES = Prism.Paths.CONTENT .. "packages/"
Prism.Paths.INDEX = Prism.Paths.PACKAGES .. ".packages"
Prism.Paths.JSON = Prism.Paths.CONTENT .. "json/"
Prism.Paths.EVENTS = Prism.Paths.JSON .. "events/"
Prism.Paths.SEASONS = Prism.Paths.JSON .. "seasons/"
Prism.Paths.SHOP = Prism.Paths.JSON .. "shop/"

-- Modules
Prism.Loader = require("loader.lua")
Prism.Builder = require("builder.lua")
Prism.Validator = require("validator.lua")

-- Initialize modules
Prism.Loader.init(Prism)
Prism.Builder.init(Prism)
Prism.Validator.init(Prism)



return Prism
