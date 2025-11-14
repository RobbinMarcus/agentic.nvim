local Logger = require("agentic.utils.logger")
local ExtmarkBlock = require("agentic.utils.extmark_block")

---@class agentic.ui.MessageWriter.BlockTracker
---@field extmark_id integer Range extmark spanning the block
---@field decoration_extmark_ids integer[] IDs of decoration extmarks from ExtmarkBlock
---@field kind string Tool call kind (read, edit, etc.)
---@field title string Tool call title/command (stored for updates)
---@field status string Current status (pending, completed, etc.)
---@field end_row? integer End row of the block (cached to avoid expensive queries)

---@class agentic.ui.MessageWriter
---@field bufnr integer
---@field ns_id integer Namespace for range extmarks
---@field decorations_ns_id integer Namespace for decoration extmarks
---@field tool_call_blocks table<string, agentic.ui.MessageWriter.BlockTracker> Map tool_call_id to extmark
---@field hl_group string
local MessageWriter = {}
MessageWriter.__index = MessageWriter

---@param bufnr integer
---@return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        hl_group = "Comment",
        ns_id = vim.api.nvim_create_namespace("agentic_tool_blocks"),
        decorations_ns_id = vim.api.nvim_create_namespace(
            "agentic_tool_decorations"
        ),
        tool_call_blocks = {},
    }, self)

    -- Make buffer readonly for users, but we can still write programmatically
    vim.bo[bufnr].modifiable = false

    vim.bo[bufnr].syntax = "markdown"

    return instance
end

---@param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    local text = nil
    if
        update.content
        and update.content.type == "text"
        and update.content.text
    then
        text = update.content.text
    else
        -- For now, only handle text content
        Logger.debug(
            "MessageWriter: Skipping non-text content or missing content"
        )
        return
    end

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })
    self:_append_lines(lines)
    self:_append_lines({ "", "" })
end

---@param lines string[]
---@return nil
function MessageWriter:_append_lines(lines)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    vim.bo[self.bufnr].modifiable = true

    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)

    vim.bo[self.bufnr].modifiable = false
end

---@param update agentic.acp.ToolCallMessage
function MessageWriter:write_tool_call_block(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    local kind = update.kind or "tool_call"
    local command = update.title or ""

    vim.bo[self.bufnr].modifiable = true

    local start_row = vim.api.nvim_buf_line_count(self.bufnr)
    local lines = self:_prepare_block_lines(update, kind, command)
    self:_append_lines(lines)
    local end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

    local decoration_ids =
        ExtmarkBlock.render_block(self.bufnr, self.decorations_ns_id, {
            header_line = start_row,
            body_start = start_row + 1,
            body_end = end_row - 1,
            footer_line = end_row,
            hl_group = self.hl_group,
        })

    -- Create range extmark for tracking (omit end_col to default to end of line)
    local extmark_id =
        vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, start_row, 0, {
            end_row = end_row,
            right_gravity = false,
        })

    -- Track externally (store kind and title for ToolCallUpdate which lacks them)
    self.tool_call_blocks[update.toolCallId] = {
        extmark_id = extmark_id,
        decoration_extmark_ids = decoration_ids,
        kind = kind,
        title = command,
        status = update.status,
        end_row = end_row,
    }

    self:_append_lines({ "", "" })
    vim.bo[self.bufnr].modifiable = false
end

---@param update agentic.acp.ToolCallUpdate
function MessageWriter:update_tool_call_block(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    local tracker = self.tool_call_blocks[update.toolCallId]
    if not tracker then
        Logger.debug(
            "Tool call block not found",
            { tool_call_id = update.toolCallId }
        )

        return
    end

    local pos, details = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        self.ns_id,
        tracker.extmark_id,
        { details = true }
    )

    if not pos then
        Logger.debug("Extmark not found", { tool_call_id = update.toolCallId })
        return
    end

    local start_row = pos[1]

    local old_end_row = tracker.end_row or (details and details.end_row)
    if not old_end_row then
        Logger.debug(
            "Could not determine end row of tool call block",
            { tool_call_id = update.toolCallId }
        )
        return
    end

    vim.bo[self.bufnr].modifiable = true

    for _, id in ipairs(tracker.decoration_extmark_ids) do
        pcall(
            vim.api.nvim_buf_del_extmark,
            self.bufnr,
            self.decorations_ns_id,
            id
        )
    end

    local new_lines =
        self:_prepare_block_lines(update, tracker.kind, tracker.title)

    vim.api.nvim_buf_set_lines(
        self.bufnr,
        start_row,
        old_end_row + 1,
        false,
        new_lines
    )

    local new_end_row = start_row + #new_lines - 1

    -- Update range extmark in-place (REUSE ID)
    vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, start_row, 0, {
        id = tracker.extmark_id, -- CRITICAL: reuse same ID
        end_row = new_end_row,
        right_gravity = false,
    })

    -- Re-apply visual decorations
    tracker.decoration_extmark_ids =
        ExtmarkBlock.render_block(self.bufnr, self.decorations_ns_id, {
            header_line = start_row,
            body_start = start_row + 1,
            body_end = new_end_row - 1,
            footer_line = new_end_row,
            hl_group = self.hl_group,
        })

    vim.bo[self.bufnr].modifiable = false

    tracker.status = update.status or tracker.status
    tracker.end_row = new_end_row
end

---@param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@param kind? string Tool call kind (required for ToolCallUpdate)
---@param title? string Tool call title (required for ToolCallUpdate)
---@return string[] lines Array of lines to render
function MessageWriter:_prepare_block_lines(update, kind, title)
    local lines = {}

    kind = kind or update.kind or "tool_call"
    title = title or update.title or ""
    local header_text = string.format("%s(%s)", kind, title)
    table.insert(lines, header_text)

    if update.content and #update.content > 0 then
        for _, content_item in ipairs(update.content) do
            if content_item.type == "content" and content_item.content then
                if content_item.content.type == "text" then
                    local text = content_item.content.text or ""
                    if text == "" then
                        table.insert(lines, "")
                    else
                        -- Split text by newlines, handling empty lines properly
                        local text_lines =
                            vim.split(text, "\n", { plain = true })
                        for _, line in ipairs(text_lines) do
                            table.insert(lines, line)
                        end
                    end
                elseif content_item.content.type == "resource" then
                    local resource_text = content_item.content.resource.text
                        or ""
                    for line in resource_text:gmatch("[^\n]+") do
                        table.insert(lines, line)
                    end
                end
            elseif content_item.type == "diff" then
                table.insert(
                    lines,
                    string.format("diff: %s", content_item.path)
                )
            end
        end
    end

    local footer_text = tostring(update.status or "")
    if footer_text ~= "" then
        table.insert(lines, footer_text)
    end

    return lines
end

function MessageWriter:destroy()
    pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, self.ns_id, 0, -1)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        self.decorations_ns_id,
        0,
        -1
    )
    self.tool_call_blocks = {}
end

return MessageWriter
