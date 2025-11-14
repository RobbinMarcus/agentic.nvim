-- The session manager class glue together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- Wheen the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local Logger = require("agentic.utils.logger")

---@class agentic._SessionManagerPrivate
local P = {}

---@class agentic.SessionManager
---@field session_id string|nil
---@field widget agentic.ui.ChatWidget
---@field agent agentic.acp.ACPClient
---@field message_writer agentic.ui.MessageWriter
---@field selected_files string[] Absolute paths of selected files to be sent with the next prompt, should be cleared after sending
local SessionManager = {}

---@param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local Config = require("agentic.config")
    local ChatWidget = require("agentic.ui.chat_widget")
    local MessageWriter = require("agentic.ui.message_writer")

    local instance = setmetatable({
        message_writer = nil,
        session_id = nil,
        current_provider = Config.provider,
        selected_files = {},
    }, self)
    self.__index = self

    local agent = AgentInstance.get_instance(Config.provider)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    instance.agent = agent

    instance.widget = ChatWidget:new(tab_page_id, function(input_text)
        local files = vim.tbl_map(function(f)
            local path = vim.fn.fnamemodify(f, ":p:~:.")
            local name = vim.fn.fnamemodify(path, ":t")

            return instance.agent:create_resource_link_content(path, name)
        end, instance.selected_files or {})

        instance.selected_files = {}

        if instance.message_writer then
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            local message_with_header = string.format(
                "## User - %s\n%s\n\n## Agent - %s",
                timestamp,
                input_text,
                instance.current_provider
            )
            instance.message_writer:write_message({
                sessionUpdate = "user_message_chunk",
                content = {
                    type = "text",
                    text = message_with_header,
                },
            })
        end

        instance.agent:send_prompt(instance.session_id, {
            {
                type = "text",
                text = input_text,
            },
            unpack(files),
        }, function(_response, err)
            if err then
                vim.notify("Error submitting prompt: " .. vim.inspect(err))
                return
            end

            vim.schedule(function()
                local timestamp = os.date("%Y-%m-%d %H:%M:%S")
                local finish_message = string.format(" 🏁 %s\n---", timestamp)
                instance.message_writer:write_message({
                    sessionUpdate = "agent_message_chunk",
                    content = {
                        type = "text",
                        text = finish_message,
                    },
                })
            end)
        end)
    end)

    instance:_add_initial_file_to_selection()

    instance.message_writer =
        MessageWriter:new(instance.widget.panels.chat.bufnr)

    ---@type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            Logger.debug("Agent error: ", err)
            vim.notify(
                "Agent error: " .. err,
                vim.log.levels.ERROR,
                { title = "🐞 Agent Error" }
            )

            -- TODO: maybe write the error to the chat widget?
        end,

        on_read_file = function(...)
            P.on_read_file(...)
        end,

        on_write_file = function(...)
            P.on_write_file(...)
        end,

        on_session_update = function(update)
            P.on_session_update(instance, update)
        end,

        on_request_permission = function(request, callback)
            -- FIXIT: Handle permission requests from the agent
        end,
    }

    agent:create_session(handlers, function(response, err)
        if err or not response then
            return
        end

        instance.session_id = response.sessionId

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        vim.schedule(function()
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            local provider_name = instance.current_provider or "unknown"
            local session_id = instance.session_id or "unknown"
            local welcome_message = string.format(
                "# Agentic - %s - %s\n- %s\n- ACP\n-----",
                provider_name,
                session_id,
                timestamp
            )

            instance.message_writer:write_message({
                sessionUpdate = "user_message_chunk",
                content = {
                    type = "text",
                    text = welcome_message,
                },
            })
        end)
    end)

    return instance
end

function SessionManager:_add_initial_file_to_selection()
    local buf_path = vim.api.nvim_buf_get_name(self.widget.main_buffer.bufnr)

    local stat = vim.uv.fs_stat(buf_path)
    if stat and stat.type == "file" then
        table.insert(self.selected_files, buf_path)
    end
end

---@param session agentic.SessionManager
---@param update agentic.acp.SessionUpdateMessage
function P.on_session_update(session, update)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
    elseif update.sessionUpdate == "agent_message_chunk" then
        session.message_writer:write_message(update)
    elseif update.sessionUpdate == "user_message_chunk" then
        session.message_writer:write_message(update)
    elseif update.sessionUpdate == "agent_thought_chunk" then
        session.message_writer:write_message(update)
    elseif update.sessionUpdate == "tool_call" then
        session.message_writer:write_tool_call_block(update)
    elseif update.sessionUpdate == "tool_call_update" then
        session.message_writer:update_tool_call_block(update)
    elseif update.sessionUpdate == "available_commands_update" then
    else
        -- TODO: Move this to Logger when confidence is high
        vim.notify(
            "Unknown session update type: "
                .. tostring(
                    ---@diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end
end

---@type agentic.acp.ClientHandlers.on_read_file
function P.on_read_file(abs_path, line, limit, callback)
    local lines, err = P._read_file_from_buf_or_disk(abs_path)
    lines = lines or {}

    if err ~= nil then
        vim.notify(
            "Agent file read error: " .. err,
            vim.log.levels.ERROR,
            { title = " Read file error" }
        )
        callback(nil)
        return
    end

    if line ~= nil and limit ~= nil then
        lines = vim.list_slice(lines, line, line + limit)
    end

    local content = table.concat(lines, "\n")
    callback(content)
end

---@type agentic.acp.ClientHandlers.on_write_file
function P.on_write_file(abs_path, content, callback)
    local file = io.open(abs_path, "w")
    if file then
        file:write(content)
        file:close()

        local buffers = vim.tbl_filter(function(bufnr)
            return vim.api.nvim_buf_is_valid(bufnr)
                and vim.fn.fnamemodify(
                        vim.api.nvim_buf_get_name(bufnr),
                        ":p"
                    )
                    == abs_path
        end, vim.api.nvim_list_bufs())

        local bufnr = next(buffers)

        if bufnr then
            vim.api.nvim_buf_call(bufnr, function()
                local view = vim.fn.winsaveview()
                vim.cmd("checktime")
                vim.fn.winrestview(view)
            end)
        end

        callback(nil)
        return
    end

    callback("Failed to write file: " .. abs_path)
end

--- Read the file content from a buffer if loaded, to get unsaved changes, or from disk otherwise
---@param abs_path string
---@return string[]|nil lines
---@return string|nil error
function P._read_file_from_buf_or_disk(abs_path)
    local ok, bufnr = pcall(vim.fn.bufnr, abs_path)
    if ok then
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            return lines, nil
        end
    end

    local stat = vim.uv.fs_stat(abs_path)
    if stat and stat.type == "directory" then
        return {}, "Cannot read a directory as file: " .. abs_path
    end

    local file, open_err = io.open(abs_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        content = content:gsub("\r\n", "\n")
        return vim.split(content, "\n"), nil
    else
        return {}, open_err
    end
end

function SessionManager:destroy()
    self.widget:destroy()
    self.message_writer:destroy()
    if self.session_id then
        self.agent:unsubscribe(self.session_id)
    end
end

return SessionManager
