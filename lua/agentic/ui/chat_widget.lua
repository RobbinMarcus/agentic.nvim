local Layout = require("nui.layout")
local Split = require("nui.split")
local event = require("nui.utils.autocmd").event

---@class agentic.ui.ChatWidgetWinIds
---@field result_container integer
---@field todos_container integer integer
---@field selected_files_container integer
---@field selected_code_container integer
---@field input_container integer

---@class agentic.ui.ChatWidgetPanels
---@field input NuiSplit
---@field chat NuiSplit
---@field todos NuiSplit
---@field files NuiSplit
---@field code NuiSplit
---@field layout NuiLayout

---@class agentic.ui.ChatWidgetMainBuffer
---@field bufnr? integer
---@field winid? integer
---@field selection? table

---@class agentic.ui.ChatWidget
---@field tab_page_id integer
---@field main_buffer agentic.ui.ChatWidgetMainBuffer The buffer where the chat widget was opened from and will display the active file
---@field panels agentic.ui.ChatWidgetPanels
---@field is_generating boolean
---@field on_submit_input fun(prompt: string) external callback to be called when user submits the input
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
---@param on_submit_input fun(prompt: string)
function ChatWidget:new(tab_page_id, on_submit_input)
    local instance = setmetatable({}, ChatWidget)

    instance.on_submit_input = on_submit_input
    instance.tab_page_id = tab_page_id
    instance.main_buffer = {
        bufnr = 0,
        winid = 0,
        selection = nil,
    }

    instance.panels = instance:_initialize()

    return instance
end

function ChatWidget:is_open()
    local win_id = self.panels.chat and self.panels.chat.winid

    if not win_id then
        return false
    end

    return vim.api.nvim_win_is_valid(win_id)
end

function ChatWidget:show()
    if not self:is_open() then
        self.panels.layout:show()
    end
end

function ChatWidget:hide()
    if self:is_open() then
        self.panels.layout:hide()
    end
end

function ChatWidget:toggle()
    if self:is_open() then
        self:hide()
    else
        self:show()
    end
end

function ChatWidget:destroy()
    self.panels.layout:unmount()
end

function ChatWidget:_submit_input()
    local lines =
        vim.api.nvim_buf_get_lines(self.panels.input.bufnr, 0, -1, false)

    local prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")

    if prompt == "" then
        return
    end

    vim.api.nvim_buf_set_lines(self.panels.input.bufnr, 0, -1, false, {})
    vim.api.nvim_win_set_cursor(self.panels.input.winid, { 1, 0 })

    self.on_submit_input(prompt)
end

---@return agentic.ui.ChatWidgetPanels
function ChatWidget:_initialize()
    self.main_buffer.winid = vim.api.nvim_get_current_win()
    self.main_buffer.bufnr = vim.api.nvim_get_current_buf()

    local chat = self._make_split({
        buf_options = {
            filetype = "AgenticChat",
            modifiable = false,
        },
    })

    local files = self._make_split({
        buf_options = {
            filetype = "AgenticFiles",
            modifiable = false,
        },
    })

    local code = self._make_split({
        buf_options = {
            filetype = "AgenticInput",
            modifiable = false,
        },
    })

    local todos = self._make_split({
        buf_options = {
            filetype = "AgenticInput",
            modifiable = false,
        },
    })

    local input = self._make_split({
        buf_options = {
            filetype = "AgenticInput",
        },
    })

    -- Only start in insert mode the first time the input panel is opened
    input:on(event.BufEnter, function()
        input:off(event.BufEnter)
        vim.cmd("startinsert!")
    end)

    input:map("n", "<C-s>", function()
        self:_submit_input()
    end)
    input:map("i", "<C-s>", function()
        self:_submit_input()
    end)
    input:map("n", "q", function()
        self:hide()
    end)

    local layout = Layout(
        {
            position = "right",
            relative = "editor",
            size = "40%",
        },
        Layout.Box({
            Layout.Box(chat, { grow = 1 }),
            Layout.Box(files, { size = 10 }),
            Layout.Box(input, { size = 15 }),
        }, { dir = "col" })
    )

    return { ---@type agentic.ui.ChatWidgetPanels
        chat = chat,
        files = files,
        input = input,
        layout = layout,
        code = code,
        todos = todos,
    }
end

---@param props nui_split_options
function ChatWidget._make_split(props)
    return Split(vim.tbl_deep_extend("force", {
        buf_options = {
            swapfile = false,
            buftype = "nofile",
        },
        win_options = {
            wrap = true,
            signcolumn = "no",
            number = false,
            relativenumber = false,
        },
    }, props))
end

return ChatWidget
