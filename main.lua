local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local DataStorage     = require("datastorage")
local Event           = require("ui/event")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LuaSettings     = require("luasettings")
local Notification    = require("ui/widget/notification")
local Screen          = Device.screen
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local T               = require("ffi/util").template
local Dispatcher = require("dispatcher")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local PinnedPopup  -- class cache (loaded once)

-- Siempre apunta al plugin de la sesión activa.
-- Se actualiza en onReaderReady para que el closure del parche
-- de ImageViewer use la instancia correcta al cambiar de libro.
local _active_plugin = nil

local PinnedElements = InputContainer:extend{
    name        = "pinnedelements",
    is_doc_only = true,
    _pins       = {},
}

-- ──────────────────────────────────────────────
-- INIT
-- ──────────────────────────────────────────────



function PinnedElements:_initStorage()
    self._data_dir = DataStorage:getDataDir() .. "/pinnedelements"
    self._img_dir  = self._data_dir .. "/images"

    for _, dir in ipairs({ self._data_dir, self._img_dir }) do
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
    end

    math.randomseed(os.time())

    local raw  = self._book_path:match("([^/]+)$") or self._book_path
    local safe = raw:gsub("[^%w%._%-]", "_"):sub(1, 80)
    self._settings = LuaSettings:open(self._data_dir .. "/" .. safe .. ".lua")
    self._pins     = self._settings:readSetting("pins") or {}
end

function PinnedElements:_saveStorage()
    if not self._settings then return end
    self._settings:saveSetting("pins", self._pins)
    self._settings:flush()
end


-- ──────────────────────────────────────────────
-- HIGHLIGHT HOOK
-- ──────────────────────────────────────────────

function PinnedElements:_hookHighlightDialog()
    if not (self.ui.highlight and self.ui.highlight.addToHighlightDialog) then
        logger.warn("PinnedElements: highlight dialog hook not available")
        return
    end
    self.ui.highlight:addToHighlightDialog("pinnedelements_pin_text", function(this)
        return {
            text = _("Pin text"),
            callback = function()
                local sel = this.selected_text
                if sel and sel.text and sel.text ~= "" then
                    self:pinSelectedText(sel.text)
                end
                UIManager:close(this.highlight_dialog)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("pinnedelements_view", function(this)
        return {
            text = _("View pins"),
            callback = function()
                UIManager:close(this.highlight_dialog)
                self:openPinnedPopup()
            end,
        }
    end)
end

-- ──────────────────────────────────────────────
-- IMAGE VIEWER PATCH
-- Mirrors imagebookmarks.koplugin's ibm_patches.lua (Patches.ImageViewer_patch /
-- add_bookmark_button) almost verbatim, since that plugin reliably shows its
-- button in the exact EPUB/PDF screenshot cases where ours used to fail.
--
-- Two important differences from our previous attempt:
--   1. We no longer force `with_title_bar = true` before calling the
--      original init. That forcing could push ImageViewer into a
--      fullscreen+title_bar combination its internal layout code doesn't
--      expect, which can throw inside the *original* init (outside our
--      pcall) and abort the whole "open image" call silently -- explaining
--      why the Pin button sometimes simply never appeared, with no error
--      visible. imagebookmarks.koplugin never does this and works fine, so
--      we just stopped doing it too.
--   2. We re-apply our wrap on EVERY onReaderReady (every time a document
--      is opened), instead of patching ImageViewer.init exactly once and
--      never touching it again. Other plugins (imagebookmarks included)
--      may reset ImageViewer.init themselves each time *their* init runs
--      (they keep their own captured "original" and rebuild their wrapper
--      around it), which would silently overwrite our wrapper and make
--      our button vanish depending on plugin load order. By re-wrapping
--      whatever the *current* ImageViewer.init is every session, we always
--      end up on top again, regardless of what other plugins did.
-- ──────────────────────────────────────────────

function PinnedElements:_patchImageViewer()
    local ok_iv, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok_iv then
        logger.warn("PinnedElements: could not load ImageViewer")
        return
    end

    -- If our wrapper is still the live ImageViewer.init, nothing to do.
    if ImageViewer.init == PinnedElements._wrapped_init then
        return
    end

    local ok_bt, ButtonTable = pcall(require, "ui/widget/buttontable")
    if not ok_bt then
        logger.warn("PinnedElements: could not load ButtonTable")
        return
    end
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom            = require("ui/geometry")

    -- Wrap whatever init is CURRENTLY installed (could be the pristine
    -- original, or another plugin's own wrapper), not a stale copy.
    local current_init = ImageViewer.init
    local wrapped
    wrapped = function(iv, ...)
        current_init(iv, ...)
        pcall(function()
            if _active_plugin then
                _active_plugin:_addPinButton(iv, ButtonTable, CenterContainer, Geom)
            end
        end)
    end

    ImageViewer.init = wrapped
    PinnedElements._wrapped_init = wrapped
end

function PinnedElements:_addPinButton(iv, ButtonTable, CenterContainer, Geom)
    -- Same guard as imagebookmarks: bail out if the structure isn't there
    -- (e.g. a true fullscreen/no-buttons viewer with no button_table at all).
    if not (iv.button_table
         and iv.button_table.buttons
         and iv.button_table.buttons[1]) then
        return
    end

    local row = iv.button_table.buttons[1]

    -- Evitar doble inserción
    for _, btn in ipairs(row) do
        if btn.id == "pinnedelements_pin" then return end
    end

    -- Insertar antes del último botón (normalmente "Close"), igual que imagebookmarks
    table.insert(row, #row, {
        id       = "pinnedelements_pin",
        text     = _("Pin"),
        callback = function()
            -- Usar _active_plugin en lugar de self capturado en el closure
            if _active_plugin then
                _active_plugin:pinImageFromViewer(iv)
            end
        end,
    })

    -- Reconstruir en el árbol de widgets, igual que hace imagecrop:
    --   • Si ButtonTable expone _buildButtons: vaciamos sus hijos y
    --     reconstruimos in-place (el objeto ya está en el FrameContainer).
    --   • Si no: creamos un nuevo ButtonTable y reemplazamos button_container[1].
    --     button_container YA está en el árbol; solo cambiamos su hijo interno.
    --     NUNCA creamos un nuevo button_container porque el árbol mantiene
    --     una referencia al original — eso es exactamente lo que imagecrop hace.
    local bt = iv.button_table
    if bt._buildButtons then
        for i = #bt, 1, -1 do bt[i] = nil end
        bt:_buildButtons()
    else
        local new_bt = ButtonTable:new{
            width       = iv.width - 2 * iv.button_padding,
            buttons     = bt.buttons,
            zero_sep    = true,
            show_parent = iv,
        }
        -- button_container ya está en el árbol; solo actualizamos su hijo.
        if iv.button_container and iv.button_container[1] == bt then
            iv.button_container[1] = new_bt
        end
        iv.button_table = new_bt
    end
end

-- Some EPUB/CRE image buffers are rotated, paletted, or low-bpp (e.g. BB4),
-- and writePNG can fail (or assert) on them directly even though it works
-- fine on the plain RGB32-ish buffers PDF tends to hand back. We try a
-- direct write first (cheap, works for the common case), and if that
-- doesn't actually produce a file, we normalize the buffer into a fresh
-- RGB32 BlitBuffer via blitFrom and retry on that instead.
local function savePNGFromBB(bb, dest_path)
    local actual_bb = bb

    -- 1. En EPUBs (crengine), la imagen puede ser una función escalable.
    -- La invocamos con factor 1 para obtener el tamaño original.
    if type(bb) == "function" then
        local ok, res = pcall(bb, 1)
        if ok and res then
            actual_bb = res
        else
            return false
        end
    end

    -- 2. Validamos que exista y sea un objeto válido (cdata o table).
    if not actual_bb or (type(actual_bb) ~= "table" and type(actual_bb) ~= "cdata") then
        return false
    end

    -- 3. Intento directo de escritura.
    local ok = pcall(function() actual_bb:writePNG(dest_path, false) end)
    if ok and lfs.attributes(dest_path, "mode") == "file" then
        return true
    end

    -- 4. Fallback: normalización a RGB32 si falla la escritura directa.
    local w, h
    pcall(function() 
        w = actual_bb:getWidth()
        h = actual_bb:getHeight()
    end)
    
    if not w or not h or w <= 0 or h <= 0 then
        return false
    end

    local ok2, norm = pcall(function()
        local nb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        nb:blitFrom(actual_bb, 0, 0, 0, 0, w, h)
        return nb
    end)
    
    if not (ok2 and norm) then
        return false
    end

    local ok3 = pcall(function() norm:writePNG(dest_path, false) end)
    pcall(function() norm:free() end)
    
    return ok3 and lfs.attributes(dest_path, "mode") == "file"
end

function PinnedElements:pinImageFromViewer(iv)
    local img_path_dest = string.format("%s/img_%d_%d.png",
        self._img_dir, os.time(), math.random(100, 999))
    local saved = false

    -- 1. iv.image: BlitBuffer (inline EPUB images, PDF page renders)
    if not saved and iv.image then
        saved = savePNGFromBB(iv.image, img_path_dest)
    end

    -- 2. iv.file: ruta de archivo (screenshots, imágenes externas)
    if not saved and iv.file and lfs.attributes(iv.file, "mode") == "file" then
        local src = io.open(iv.file, "rb")
        if src then
            local dst = io.open(img_path_dest, "wb")
            if dst then
                dst:write(src:read("*a"))
                dst:close()
                saved = true
            end
            src:close()
        end
    end

    -- 3. iv._bb: BlitBuffer decodificado (fallback universal)
    if not saved and iv._bb then
        saved = savePNGFromBB(iv._bb, img_path_dest)
    end

    if not saved then
        logger.warn("PinnedElements: could not extract image from viewer",
            "image=", iv.image ~= nil, "file=", iv.file, "_bb=", iv._bb ~= nil)
        UIManager:show(Notification:new{ text = _("Could not pin image") })
        return
    end

    local pageno = 0
    if self.ui and self.ui.view and self.ui.view.state then
        pageno = self.ui.view.state.page or 0
    end

    local label = pageno > 0
        and T(_("Image p.%1"), pageno)
        or  _("Image")
    -- Si la imagen viene de un screenshot, usar su título como label
    if iv.title_text and iv.title_text ~= "" then
        label = iv.title_text
    end

    table.insert(self._pins, {
        id       = tostring(os.time()) .. tostring(math.random(100, 999)),
        type     = "image",
        page     = pageno,
        label    = label,
        img_path = img_path_dest,
        created  = os.time(),
    })
    self:_saveStorage()
    UIManager:show(Notification:new{ text = _("Image pinned") })
end

-- ──────────────────────────────────────────────
-- ACCIONES DE ANCLADO
-- ──────────────────────────────────────────────

function PinnedElements:pinCurrentPage()
    local pageno = self.ui.view.state.page
    local tmp    = self._img_dir .. "/_tmp.png"
    Screen:shot(tmp)

    local img_path = nil
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if ok then
        local tw = math.floor(Screen:getWidth()  * 0.22)
        local th = math.floor(Screen:getHeight() * 0.22)
        local bb = RenderImage:renderImageFile(tmp, false, tw, th)
        if bb then
            img_path = string.format("%s/page_%d_%d.png",
                                     self._img_dir, pageno, os.time())
            bb:writePNG(img_path, false)
            bb:free()
        end
    end
    pcall(os.remove, tmp)

    table.insert(self._pins, {
        id       = tostring(os.time()) .. tostring(math.random(100, 999)),
        type     = "page",
        page     = pageno,
        label    = T(_("Page %1"), pageno),
        img_path = img_path,
        created  = os.time(),
    })
    self:_saveStorage()
    UIManager:show(Notification:new{ text = T(_("Page %1 pinned"), pageno) })
end

function PinnedElements:pinSelectedText(text)
    local pageno  = self.ui.view.state.page
    local preview = #text > 72 and text:sub(1, 72) .. "..." or text

    table.insert(self._pins, {
        id      = tostring(os.time()) .. tostring(math.random(100, 999)),
        type    = "text",
        page    = pageno,
        label   = preview,
        text    = text,
        created = os.time(),
    })
    self:_saveStorage()
    UIManager:show(Notification:new{ text = _("Text pinned") })
end

-- ──────────────────────────────────────────────
-- POPUP
-- ──────────────────────────────────────────────

function PinnedElements:openPinnedPopup()
    if not PinnedPopup then
        PinnedPopup = dofile(_dir .. "pinnedpopup.lua")
    end
    UIManager:show(PinnedPopup:new{
        pins        = self._pins,
        onGotoPage  = function(page)
            self.ui:handleEvent(Event:new("GotoPage", page))
        end,
        onDeletePin = function(pin_id)
            self:_deletePin(pin_id)
        end,
    })
end

function PinnedElements:_deletePin(pin_id)
    for i, pin in ipairs(self._pins) do
        if pin.id == pin_id then
            if pin.img_path then pcall(os.remove, pin.img_path) end
            table.remove(self._pins, i)
            break
        end
    end
    self:_saveStorage()
end

-- ──────────────────────────────────────────────
-- MENU
-- ──────────────────────────────────────────────

function PinnedElements:addToMainMenu(menu_items)
    menu_items.pinned_elements = {
        text = _("Pinned Elements"),
        sub_item_table = {
            {
                text     = _("Pin this page"),
                callback = function() self:pinCurrentPage() end,
            },
            {
                text     = _("View pinned elements"),
                callback = function() self:openPinnedPopup() end,
            },
            {
                text_func = function()
                    local count = self._pins and #self._pins or 0
                    return T(_("Clear all pins (%1)"), count)
                end,
                enabled_func = function()
                    return self._pins ~= nil and #self._pins > 0
                end,
                callback = function()
                    if not self._pins then return end
                    for _, p in ipairs(self._pins) do
                        if p.img_path then pcall(os.remove, p.img_path) end
                    end
                    self._pins = {}
                    self:_saveStorage()
                end,
            },
        },
    }
end

function PinnedElements:onCloseDocument()
    self:_saveStorage()
end

-- ──────────────────────────────────────────────
-- INIT
-- ──────────────────────────────────────────────

function PinnedElements:onDispatcherRegisterActions()
    Dispatcher:registerAction("pinnedelements_open_popup", {
        category = "none",
        event    = "OpenPinnedPopup",
        title    = _("Pinned Elements"),
        desc     = _("Open pinned elements popup"),
        general  = true, -- Esta línea hace que sea visible en el menú
    })
end

function PinnedElements:init()
    self:onDispatcherRegisterActions()
    -- Parchear ImageViewer al cargar el plugin, igual que hace imagecrop.
    -- Esto garantiza que el botón Pin esté presente desde la primera apertura
    -- de imagen, sin esperar a que se abra un documento (onReaderReady).
    self:_patchImageViewer()
end

function PinnedElements:onReaderReady()
    _active_plugin            = self
    _G.PinnedElements_active  = self   -- accessed by imagecrop.koplugin
    self._book_path    = self.ui.document.file
    self:_initStorage()

    self:onDispatcherRegisterActions()
    self:_hookHighlightDialog()
    -- Re-parcheamos por si otro plugin sobreescribió IV.init después de nuestro init().
    self:_patchImageViewer()
end

function PinnedElements:onOpenPinnedPopup()
    self:openPinnedPopup()
    return true
end
return PinnedElements