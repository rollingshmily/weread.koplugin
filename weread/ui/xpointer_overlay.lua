--[[--
Prototype renderer for plugin-owned XPointer annotations.

The records are deliberately kept outside KOReader's annotation array.  This
view module projects only the records intersecting the current CREngine view
to screen rectangles and paints them in ReaderView's existing paint pass.

This module has no KOReader imports so its visibility filtering, cache and hit
testing can be exercised by the standalone Lua specs.
--]]--

local Overlay = {}
Overlay.__index = Overlay

local function inside(rect, pos, padding)
    if not rect or not pos then return false end
    padding = padding or 0
    return pos.x >= rect.x - padding
        and pos.x <= rect.x + rect.w + padding
        and pos.y >= rect.y - padding
        and pos.y <= rect.y + rect.h + padding
end

function Overlay:new(opts)
    opts = opts or {}
    return setmetatable({
        records = opts.records or {},
        records_ordered = opts.records_ordered == true,
        enabled = opts.enabled ~= false,
        cache = {},
        visible = {},
        generation = 1,
        clock = opts.clock or os.clock,
        hit_padding = tonumber(opts.hit_padding) or 3,
        last_metrics = {
            candidates = 0,
            boxes = 0,
            elapsed_ms = 0,
            cache_hit = false,
        },
    }, self)
end

function Overlay:setRecords(records, ordered)
    self.records = type(records) == "table" and records or {}
    self.records_ordered = ordered == true
    self._ordered_prefix_ends = nil
    self:invalidate()
end

function Overlay:setEnabled(enabled)
    self.enabled = enabled ~= false
    self.visible = {}
end

function Overlay:invalidate()
    self.generation = self.generation + 1
    self.cache = {}
    self.visible = {}
end

function Overlay:resetLayout()
    self._ordered_prefix_ends = nil
    self:invalidate()
end

function Overlay:_orderedStart(document, page_start)
    if not self.records_ordered or not page_start
        or type(document.compareXPointers) ~= "function" then return 1 end
    local prefix = self._ordered_prefix_ends
    if not prefix then
        prefix = {}
        local latest
        for index, record in ipairs(self.records) do
            if type(record) ~= "table" or not record.pos0 or not record.pos1 then
                return 1
            end
            if not latest then
                latest = record.pos1
            else
                local ok, before = pcall(document.compareXPointers,
                    document, latest, record.pos1)
                if not ok then return 1 end
                if before == 1 then latest = record.pos1 end
            end
            prefix[index] = latest
        end
        self._ordered_prefix_ends = prefix
    end
    local low, high = 1, #prefix + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        if middle > #prefix then
            high = middle
        else
            local ok, before = pcall(document.compareXPointers,
                document, prefix[middle], page_start)
            if not ok then return 1 end
            if before == 1 then low = middle + 1 else high = middle end
        end
    end
    return low
end

local function draw_boxes(overlay, bb, x, y, boxes)
    overlay.visible = {}
    for _, entry in ipairs(boxes) do
        overlay.visible[#overlay.visible + 1] = entry
        -- Reuse KOReader's native underline renderer in ReaderView's existing
        -- paint pass, without requesting an additional e-ink refresh.
        overlay.view:drawHighlightRect(
            bb, x, y, entry.rect, "underscore", nil, false
        )
    end
end

function Overlay:_computeVisible()
    local document = self.ui and self.ui.document
    local view = self.view
    if not document or not view or self.ui.paging then
        return {}, 0
    end
    if type(document.getCurrentPos) ~= "function"
        or type(document.getPosFromXPointer) ~= "function"
        or type(document.getScreenBoxesFromPositions) ~= "function" then
        return {}, 0
    end

    local top = tonumber(document:getCurrentPos()) or 0
    local height = self.ui.dimen and tonumber(self.ui.dimen.h) or 0
    local visible_pages = 1
    if type(document.getVisiblePageCount) == "function" then
        local ok_count, count = pcall(document.getVisiblePageCount, document)
        visible_pages = ok_count and tonumber(count) or 1
    end
    local bottom = top + height * math.max(1, visible_pages or 1)
    local visible = {}
    local candidates = 0

    local page_start
    if document.getCurrentPage and document.getPageXPointer then
        local ok_page, current_page = pcall(document.getCurrentPage, document)
        if ok_page then
            local ok_xp, value = pcall(document.getPageXPointer, document, current_page)
            if ok_xp then page_start = value end
        end
    end
    local first = self:_orderedStart(document, page_start)
    for index = first, #self.records do
        local record = self.records[index]
        if type(record) == "table" and record.pos0 and record.pos1 then
            local ok_start, start_pos = pcall(
                document.getPosFromXPointer, document, record.pos0
            )
            local ok_end, end_pos = pcall(
                document.getPosFromXPointer, document, record.pos1
            )
            if ok_start and ok_end and tonumber(start_pos) and tonumber(end_pos)
                and start_pos <= bottom and end_pos >= top then
                candidates = candidates + 1
                local ok_boxes, boxes = pcall(
                    document.getScreenBoxesFromPositions,
                    document, record.pos0, record.pos1, true
                )
                if ok_boxes and type(boxes) == "table" then
                    for _, rect in ipairs(boxes) do
                        if type(rect) == "table" and tonumber(rect.h) ~= 0 then
                            visible[#visible + 1] = {
                                rect = rect,
                                record = record,
                            }
                        end
                    end
                end
            elseif self.records_ordered and tonumber(start_pos)
                and start_pos > bottom then
                break
            end
        end
    end
    return visible, candidates
end

function Overlay:paintTo(bb, x, y)
    local started = self.clock()
    if not self.enabled or #self.records == 0 then
        self.visible = {}
        self.last_metrics = {
            candidates = 0,
            boxes = 0,
            elapsed_ms = (self.clock() - started) * 1000,
            cache_hit = false,
        }
        return
    end

    local document = self.ui and self.ui.document
    if not document then return end
    local page = type(document.getCurrentPage) == "function"
        and document:getCurrentPage() or 0
    local can_cache = self.view and self.view.view_mode == "page"
    local cache_key = tostring(self.generation) .. ":" .. tostring(page)
    local cached = can_cache and self.cache[cache_key] or nil
    local boxes, candidates
    if cached then
        boxes = cached.boxes
        candidates = cached.candidates
    else
        local ok_visible, computed, count = pcall(self._computeVisible, self)
        if not ok_visible then
            self.visible = {}
            self.last_metrics = {
                candidates = 0,
                boxes = 0,
                elapsed_ms = (self.clock() - started) * 1000,
                cache_hit = false,
            }
            return
        end
        boxes, candidates = computed, count
        if can_cache then
            self.cache[cache_key] = {
                boxes = boxes,
                candidates = candidates,
            }
        end
    end
    draw_boxes(self, bb, x, y, boxes)
    self.last_metrics = {
        candidates = candidates,
        boxes = #boxes,
        elapsed_ms = (self.clock() - started) * 1000,
        cache_hit = cached ~= nil,
    }
end

function Overlay:hitTest(pos)
    for index = #self.visible, 1, -1 do
        local entry = self.visible[index]
        if inside(entry.rect, pos, self.hit_padding) then
            return entry.record
        end
    end
end

return Overlay
