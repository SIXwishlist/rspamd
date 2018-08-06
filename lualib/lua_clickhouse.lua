--[[
Copyright (c) 2018, Vsevolod Stakhov <vsevolod@highsecure.ru>
Copyright (c) 2018, Mikhail Galanin <mgalanin@mimecast.com>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

local rspamd_logger = require "rspamd_logger"
local rspamd_http = require "rspamd_http"

local exports = {}
local N = 'clickhouse'

local default_timeout = 10.0

local function escape_spaces(query)
  return query:gsub('%s', '%%20')
end

local function clickhouse_quote(str)
  if str then
    return str:gsub('[\'\\]', '\\%1'):lower()
  end

  return ''
end

-- Converts an array to a string suitable for clickhouse
local function array_to_string(ar)
  for i,elt in ipairs(ar) do
    if type(elt) == 'string' then
      ar[i] = '\'' .. clickhouse_quote(elt) .. '\''
    else
      ar[i] = tostring(elt)
    end
  end

  return table.concat(ar, ',')
end

-- Converts a row into TSV, taking extra care about arrays
local function row_to_tsv(row)

  for i,elt in ipairs(row) do
    if type(elt) == 'table' then
      row[i] = '[' .. array_to_string(elt) .. ']'
    else
      row[i] = tostring(elt) -- Assume there are no tabs there
    end
  end

  return table.concat(row, '\t')
end

-- Parses JSONEachRow reply from CH
local function parse_clickhouse_response(params, data)
  local lua_util = require "lua_util"
  local ucl = require "ucl"

  rspamd_logger.debugm(N, params.log_obj, "got clickhouse response: %s", data)
  if data == nil then
    -- clickhouse returned no data (i.e. empty result set): exiting
    return {}
  end

  local function parse_string(s)
    local parser = ucl.parser()
    local res, err = parser:parse_string(s)
    if not res then
      rspamd_logger.errx(params.log_obj, 'Parser error: %s', err)
      return nil
    end
    return parser:get_object()
  end

  -- iterate over rows and parse
  local ch_rows = lua_util.str_split(data, "\n")
  local parsed_rows = {}
  for _, plain_row in pairs(ch_rows) do
    if plain_row and plain_row:len() > 1 then
      local parsed_row = parse_string(plain_row)
      if parsed_row then
        table.insert(parsed_rows, parsed_row)
      end
    end
  end

  return parsed_rows
end

-- Helper to generate HTTP closure
local function mk_http_select_cb(upstream, params, ok_cb, fail_cb)
  local function http_cb(err_message, code, data, _)
    if code ~= 200 or err_message then
      if not err_message then err_message = data end
      local ip_addr = upstream:get_addr():to_string(true)
      rspamd_logger.errx(params.log_obj,
          "request failed on clickhouse server %s: %s",
          ip_addr, err_message)

      if fail_cb then
        fail_cb(params, err_message, data)
      end
      upstream:fail()
    else
      upstream:ok()
      rspamd_logger.debugm(N, params.log_obj,
          "http_cb ok: %s, %s, %s, %s", err_message, code, data, _)
      local rows = parse_clickhouse_response(params, data)

      if rows then
        if ok_cb then
          ok_cb(params, rows)
        end
      else
        if fail_cb then
          fail_cb(params, 'failed to parse reply', data)
        end
      end
    end
  end

  return http_cb
end

-- Helper to generate HTTP closure
local function mk_http_insert_cb(upstream, params, ok_cb, fail_cb)
  local function http_cb(err_message, code, data, _)
    if code ~= 200 or err_message then
      if not err_message then err_message = data end
      local ip_addr = upstream:get_addr():to_string(true)
      rspamd_logger.errx(params.log_obj,
          "request failed on clickhouse server %s: %s",
          ip_addr, err_message)

      if fail_cb then
        fail_cb(params, err_message, data)
      end
      upstream:fail()
    else
      upstream:ok()
      rspamd_logger.debugm(N, params.log_obj,
          "http_cb ok: %s, %s, %s, %s", err_message, code, data, _)

      if ok_cb then
        ok_cb(params, data)
      end
    end
  end

  return http_cb
end

--[[[
-- @function lua_clickhouse.select(upstream, settings, params, query,
      ok_cb, fail_cb)
-- Make select request to clickhouse
-- @param {upstream} upstream clickhouse server upstream
-- @param {table} settings global settings table:
--   * use_gsip: use gzip compression
--   * timeout: request timeout
--   * no_ssl_verify: skip SSL verification
--   * user: HTTP user
--   * password: HTTP password
-- @param {params} HTTP request params
-- @param {string} query select query (passed in HTTP body)
-- @param {function} ok_cb callback to be called in case of success
-- @param {function} fail_cb callback to be called in case of some error
-- @return {boolean} whether a connection was successful
-- @example
--
--]]
exports.select = function (upstream, settings, params, query, ok_cb, fail_cb)
  local http_params = {}

  for k,v in pairs(params) do http_params[k] = v end

  http_params.callback = mk_http_select_cb(upstream, http_params, ok_cb, fail_cb)
  http_params.gzip = settings.use_gzip
  http_params.mime_type = 'text/plain'
  http_params.timeout = settings.timeout or default_timeout
  http_params.no_ssl_verify = settings.no_ssl_verify
  http_params.user = settings.user
  http_params.password = settings.password
  http_params.body = query
  http_params.log_obj = params.task or params.config

  rspamd_logger.debugm(N, http_params.log_obj, "clickhouse select request: %s", params.body)

  if not http_params.url then
    local connect_prefix = "http://"
    if settings.use_https then
      connect_prefix = 'https://'
    end
    local ip_addr = upstream:get_addr():to_string(true)
    http_params.url = connect_prefix .. ip_addr .. '/?default_format=JSONEachRow'
  end

  return rspamd_http.request(http_params)
end

--[[[
-- @function lua_clickhouse.insert(upstream, settings, params, query, rows,
      ok_cb, fail_cb)
-- Insert data rows to clickhouse
-- @param {upstream} upstream clickhouse server upstream
-- @param {table} settings global settings table:
--   * use_gsip: use gzip compression
--   * timeout: request timeout
--   * no_ssl_verify: skip SSL verification
--   * user: HTTP user
--   * password: HTTP password
-- @param {params} HTTP request params
-- @param {string} query select query (passed in `query` request element with spaces escaped)
-- @param {table|mixed} rows mix of strings, numbers or tables (for arrays)
-- @param {function} ok_cb callback to be called in case of success
-- @param {function} fail_cb callback to be called in case of some error
-- @return {boolean} whether a connection was successful
-- @example
--
--]]
exports.insert = function (upstream, settings, params, query, rows,
                              ok_cb, fail_cb)
  local fun = require "fun"
  local http_params = {}

  for k,v in pairs(params) do http_params[k] = v end

  http_params.callback = mk_http_insert_cb(upstream, http_params, ok_cb, fail_cb)
  http_params.gzip = settings.use_gzip
  http_params.mime_type = 'text/plain'
  http_params.timeout = settings.timeout or default_timeout
  http_params.no_ssl_verify = settings.no_ssl_verify
  http_params.user = settings.user
  http_params.password = settings.password
  http_params.body = {table.concat(fun.totable(fun.map(function(row)
    return row_to_tsv(row)
  end), rows), '\n'), '\n'}
  http_params.log_obj = params.task or params.config

  if not http_params.url then
    local connect_prefix = "http://"
    if settings.use_https then
      connect_prefix = 'https://'
    end
    local ip_addr = upstream:get_addr():to_string(true)
    http_params.url = string.format('%s%s/?query=%s%%20FORMAT%%20TabSeparated',
        connect_prefix,
        ip_addr,
        escape_spaces(query))
  end

  return rspamd_http.request(http_params)
end

--[[[
-- @function lua_clickhouse.generic(upstream, settings, params, query,
      ok_cb, fail_cb)
-- Make a generic request to Clickhouse (e.g. alter)
-- @param {upstream} upstream clickhouse server upstream
-- @param {table} settings global settings table:
--   * use_gsip: use gzip compression
--   * timeout: request timeout
--   * no_ssl_verify: skip SSL verification
--   * user: HTTP user
--   * password: HTTP password
-- @param {params} HTTP request params
-- @param {string} query Clickhouse query (passed in `query` request element with spaces escaped)
-- @param {function} ok_cb callback to be called in case of success
-- @param {function} fail_cb callback to be called in case of some error
-- @return {boolean} whether a connection was successful
-- @example
--
--]]
exports.generic = function (upstream, settings, params, query,
                           ok_cb, fail_cb)
  local http_params = {}

  for k,v in pairs(params) do http_params[k] = v end

  http_params.callback = mk_http_insert_cb(upstream, http_params, ok_cb, fail_cb)
  http_params.gzip = settings.use_gzip
  http_params.mime_type = 'text/plain'
  http_params.timeout = settings.timeout or default_timeout
  http_params.no_ssl_verify = settings.no_ssl_verify
  http_params.user = settings.user
  http_params.password = settings.password
  http_params.log_obj = params.task or params.config

  if not http_params.url then
    local connect_prefix = "http://"
    if settings.use_https then
      connect_prefix = 'https://'
    end
    local ip_addr = upstream:get_addr():to_string(true)
    http_params.url = connect_prefix .. ip_addr .. '/?default_format=JSONEachRow'
  end

  return rspamd_http.request(http_params)
end


return exports