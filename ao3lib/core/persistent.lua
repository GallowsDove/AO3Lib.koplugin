-- Keep durable plugin data in KOReader's backed-up settings directory.
local DataStorage = require('datastorage')
local util = require('util')
local logger = require('logger')
local M = {}

function M.directory()
    return DataStorage:getSettingsDir() .. '/ao3lib'
end

function M.path(name)
    if not util.makePath(M.directory()) then logger.err('Cannot create AO3Lib settings directory') end
    return M.directory() .. '/' .. name
end

return M
