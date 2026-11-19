
local DataStorage = require("datastorage")
local logger = require("logger")
local DownloadedFanfics = require("ao3lib.library.history")
local util = require("frontend/util")
local Paths = require("ao3lib.core.paths")
local lfs = require("libs/libkoreader-lfs")

local config_instance = nil

local function createConfig()
    local config = {}
    local settings_path = DataStorage:getSettingsDir() .. "/fanfic.lua"
    local cached_settings, cached_stamp
    local function stamp()
        local stat = lfs.attributes(settings_path)
        return stat and table.concat({stat.size or 0, stat.modification or 0, stat.change or 0}, ":") or "missing"
    end
    local function settings()
        local current_stamp = stamp()
        if not cached_settings or current_stamp ~= cached_stamp then
            cached_settings = require("luasettings"):open(settings_path)
            cached_stamp = current_stamp
        end
        return cached_settings
    end
    local copy = require("ao3lib.core.table").deepCopy
    local function persist(store)
        store:flush()
        cached_stamp = stamp()
    end

    config.default_settings = {
        AO3_domain = "https://archiveofourown.org",
        show_adult_warning = true,
        formatted_work_view = false,
        work_view_font_size = 18,
        ao3_eink_symbols = false,
        version = 1,
        bookmarkedFandoms = {
            "原神 | Genshin Impact (Video Game)",
            "Miraculous Ladybug",
            "Marvel Cinematic Universe",
            "Star Wars - All Media Types",
        },
        filename_template = "%I",
        author_folders = true,
        fanfic_folder_path = Paths.getHomeDirectory() .. "/Downloads",
        show_current_chapter = true
    }

    function config:init()
        if not util.fileExists(DataStorage:getSettingsDir() .. "/fanfic.lua") then
            self:setup()
        end

        if self:readSetting("version") == nil then
            self:updateSettingsFile_1()
        end
    end

    function config:setup()
        util.makePath(Paths:getHomeDirectory())
        util.makePath(Paths:getHomeDirectory().."/Downloads/")
        self:setDefault()
    end

    function config:setDefault()
        local store = settings()
        for setting, value in pairs(self.default_settings) do
            if store:readSetting(setting) == nil then store:saveSetting(setting, copy(value)) end
        end
        persist(store)
    end

    function config:updateSettingsFile_1()
        -- update filter menu
        local filter_set = config:readSetting("saved_filters", {} )
        local new_filter_set = {}

        for __, filter in pairs(filter_set) do
            logger.dbg(filter)
            new_filter_set[filter.title] = filter
        end

        config:saveSetting("saved_filters", new_filter_set)

        -- update chapter menu
        DownloadedFanfics.updateDownloadFile_1()
        config:saveSetting("version", 1)

    end

    function config:readSetting(key, default)
        local value = settings():readSetting(key)
        if value == nil then
            if default == nil then default = self.default_settings[key] end
            value = default
        end
        -- Callers edit returned tables before explicitly saving them. Keep the
        -- cached settings isolated, as separate file reads were previously.
        return copy(value)
    end

    function config:saveSetting(key, value)
        local store = settings()
        store:saveSetting(key, copy(value))
        persist(store)
    end


    function config:onFlushSettings(settings)
        if self and self.updated then
            persist(settings)
            self.updated = nil
        end
    end

    return config

end

-- Return the singleton instance
return (function()
    if not config_instance then
        config_instance = createConfig()
        config_instance:init()
    end
    return config_instance
end)()
