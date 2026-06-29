local Blitbuffer      = require("ffi/blitbuffer")
local BD              = require("ui/bidi")
local ButtonDialog    = require("ui/widget/buttondialog")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local InputDialog     = require("ui/widget/inputdialog")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextViewer      = require("ui/widget/textviewer")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local T               = require("ffi/util").template

local PAD       = Size.padding.default
local FACE_MAIN = Font:getFace("cfont", 16)
local FACE_SUB  = Font:getFace("cfont", 14)
local FACE_ICON = Font:getFace("cfont", 22)
local FACE_NAV  = Font:getFace("cfont", 17)

local NAV_H = Screen:scaleBySize(46)
local BAR_H = TitleBar:getHeight() or Screen:scaleBySize(45)

local W, H, POPUP_W, POPUP_H, THUMB_SIZE, ITEM_H

local function updateDimensions()
    W          = Screen:getWidth()
    H          = Screen:getHeight()
    POPUP_W    = math.floor(W * 0.90)
    POPUP_H    = math.floor(H * 0.82)
    THUMB_SIZE = math.floor(math.min(W, H) * 0.20)
    ITEM_H     = THUMB_SIZE + PAD * 2
end

-- ── NavButton ─────────────────────────────────────────────────────────────────
-- Widget reutilizable para todos los botones de navegación.

local NavButton = InputContainer:extend{
    label_text = nil,
    enabled    = true,
    callback   = nil,
    width      = nil,
    height     = nil,
}

function NavButton:init()
    local h = self.height or NAV_H
    self.dimen = Geom:new{ w = self.width, h = h }
    local color = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        TextWidget:new{
            text    = self.label_text,
            face    = FACE_NAV,
            fgcolor = color,
        },
    }
    if self.enabled then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
end

function NavButton:onTap()
    if self.callback then self.callback() end
    return true
end

-- ── PinnedImageViewer ─────────────────────────────────────────────────────────
-- Visor de imagen fiel al nativo: popup centrado (no fullscreen), con pan/zoom
-- y gestos completos. Botones de acción siempre visibles; barra de navegación
-- con celdas separadas (ButtonTable) debajo de los botones de acción.

local PinnedImageViewer = InputContainer:extend{
    pin             = nil,
    index           = nil,
    total           = nil,
    onNavigate      = nil,
    scale_factor    = 0,
    rotated         = false,
    _scale_to_fit   = nil,
    _center_x_ratio = 0.5,
    _center_y_ratio = 0.5,
    _panning        = false,
    _image_wg       = nil,
    pan_threshold   = Screen:scaleBySize(5),
    image_padding   = Size.margin.small,
    button_padding  = Size.padding.default,
}

function PinnedImageViewer:init()
    -- Dimensiones de popup (igual que PinnedPopup / visor nativo)
    updateDimensions()
    local sw = POPUP_W
    local sh = POPUP_H
    self._sw = sw
    self._sh = sh
    -- El InputContainer cubre toda la pantalla para capturar gestos
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    if self._scale_to_fit == nil then
        self._scale_to_fit = (self.scale_factor == 0)
    end

    -- Teclas físicas
    if Device:hasKeys() then
        self.key_events = {
            Close   = { { Device.input.group.Back } },
            ZoomIn  = { { Device.input.group.PgBack } },
            ZoomOut = { { Device.input.group.PgFwd } },
        }
    end

    -- Gestos táctiles sobre toda la pantalla
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.ges_events = {
            Tap         = { GestureRange:new{ ges = "tap",           range = range } },
            Spread      = { GestureRange:new{ ges = "spread",        range = range } },
            Pinch       = { GestureRange:new{ ges = "pinch",         range = range } },
            Hold        = { GestureRange:new{ ges = "hold",          range = range } },
            HoldRelease = { GestureRange:new{ ges = "hold_release",  range = range } },
            Pan         = { GestureRange:new{ ges = "pan",           range = range } },
            PanRelease  = { GestureRange:new{ ges = "pan_release",   range = range } },
            Swipe       = { GestureRange:new{ ges = "swipe",         range = range } },
            MultiSwipe  = { GestureRange:new{ ges = "multiswipe",    range = range } },
        }
    end

    -- ── TitleBar ──────────────────────────────────────────────────────────────
    self.show_action_buttons = false -- Variable de estado para los botones


    -- ── Botones de acción: Tamaño original/Ajustar · Rotar · Cerrar ──────────
    local action_buttons = {{
        {
            id   = "scale",
            text = self._scale_to_fit and _("Original size") or _("Scale"),
            callback = function()
                self.scale_factor  = self._scale_to_fit and 1 or 0
                self._scale_to_fit = not self._scale_to_fit
                self._center_x_ratio = 0.5
                self._center_y_ratio = 0.5
                self:update()
            end,
        },
        {
            id   = "rotate",
            text = self.rotated and _("No rotation") or _("Rotate"),
            callback = function()
                self.rotated = not self.rotated
                self:update()
            end,
        },
        {
            id   = "close",
            text = _("Close"),
            callback = function() self:onClose() end,
        },
    }}
    self.button_table = ButtonTable:new{
        width       = sw - 2 * self.button_padding,
        buttons     = action_buttons,
        zero_sep    = true,
        show_parent = self,
    }
    self.button_container = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = self.button_table:getSize().h },
        self.button_table,
    }

    -- ── Barra de nav: ButtonTable (celdas separadas igual que en el nativo) ───
    self.nav_separator = LineWidget:new{
        dimen = Geom:new{ w = sw, h = Size.line.thin },
    }
    self.nav_table, self.nav_container = self:_buildNavBar(sw)

    -- ── Marco del popup (borde y radio como PinnedPopup) ──────────────────────
    self.frame_elements = VerticalGroup:new{ align = "left" }
    self.main_frame = FrameContainer:new{
        radius     = 8,
        padding    = 0,
        margin     = 0,
        bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        self.frame_elements,
    }
    -- Centrado sobre la pantalla completa (igual que PinnedPopup)
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.main_frame,
    }

    self:update()
end

-- Reconstruye la vista; botones de acción y nav siempre visibles
function PinnedImageViewer:update()
    self:_clean_image_wg()

    local sw = self._sw
    local sh = self._sh
    local orig_dimen = self.main_frame.dimen

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    -- 0) TitleBar (Se recrea aquí para capturar los cambios de nombre)
    if self.title_bar then self.title_bar:free() end
    self.title_bar = TitleBar:new{
        width            = sw,
        title            = self.pin.label,
        title_multilines = true,
        with_bottom_line = true,
        left_icon        = "appbar.menu",
        left_icon_tap_callback = function() self:_showMenu() end,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }

    -- 1) TitleBar
    table.insert(self.frame_elements, self.title_bar)

    -- 2) Índice donde irá la imagen
    local img_idx = #self.frame_elements + 1

    -- 3) Botones de acción (visibles según estado)
    if self.show_action_buttons then
        local scale_btn = self.button_table:getButtonById("scale")
        scale_btn:setText(
            self._scale_to_fit and _("Original size") or _("Scale"),
            scale_btn.width)
        local rotate_btn = self.button_table:getButtonById("rotate")
        rotate_btn:setText(
            self.rotated and _("No rotation") or _("Rotate"),
            rotate_btn.width)
        table.insert(self.frame_elements, self.button_container)
    end

    -- 4) Separador + barra de navegación (siempre visible)
    table.insert(self.frame_elements, self.nav_separator)
    table.insert(self.frame_elements, self.nav_container)

    -- 5) Altura disponible para la imagen
    local fixed_h = self.frame_elements:getSize().h
    local img_h   = sh - fixed_h

    -- 6) ImageWidget
    self:_new_image_wg(sw, img_h)
    table.insert(self.frame_elements, img_idx, self.image_container)
    self.frame_elements:resetLayout()

    self.dithered = true
    local wfm = Device:hasKaleidoWfm() and "partial" or "ui"
    UIManager:setDirty(self, function()
        return wfm, self.main_frame.dimen:combine(orig_dimen or self.main_frame.dimen), true
    end)
end

function PinnedImageViewer:_showMenu()
    local dialog
    dialog = ButtonDialog:new{
        title   = self.pin.label,
        buttons = {
            {{
                text     = _("Renombrar"),
                callback = function()
                    UIManager:close(dialog) -- Cierra el menú principal
                    
                    local input_dialog
                    input_dialog = InputDialog:new{
                        title = _("Renombrar imagen"),
                        input = self.pin.label,
                        buttons = {{
                            {
                                text = _("Cancelar"),
                                callback = function()
                                    UIManager:close(input_dialog)
                                end,
                            },
                            {
                                text = _("Aceptar"),
                                callback = function()
                                    local new_text = input_dialog:getInputValue()
                                    if new_text and new_text ~= "" then
                                        self.pin.label = new_text
                                        self:update() 
                                    end
                                    UIManager:close(input_dialog)
                                end,
                            },
                        }}
                    }
                    UIManager:show(input_dialog)
                end,
            }},
            {{
                text     = _("Conmutar botones de acción"),
                callback = function()
                    UIManager:close(dialog)
                    self.show_action_buttons = not self.show_action_buttons
                    self:update()
                end,
            }},
            {{
                text     = _("Ir a la página"),
                callback = function()
                    UIManager:close(dialog)
                    self:onClose()
                    if self.onGotoPage then self.onGotoPage(self.pin.page) end
                end,
            }},
            {{
                text     = _("Cancelar"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Crea un nuevo ImageWidget con pan/zoom/rotación (igual que ImageViewer:_new_image_wg)
function PinnedImageViewer:_new_image_wg(sw, img_h)
    -- Padding lateral/vertical (siempre presente, pues la TitleBar siempre está)
    local max_w = sw    - self.image_padding * 2
    local max_h = img_h - self.image_padding * 2

    local rotation_angle = 0
    if self.rotated then
        -- Retrato: rotar 90 °; paisaje: rotar 270 ° (igual que ImageViewer)
        rotation_angle = (Screen:getWidth() <= Screen:getHeight()) and 90 or 270
    end

    self._image_wg = ImageWidget:new{
        file             = self.pin.img_path,
        image_disposable = false,
        file_do_cache    = false,
        alpha            = true,
        width            = max_w,
        height           = max_h,
        rotation_angle   = rotation_angle,
        scale_factor     = self.scale_factor,
        center_x_ratio   = self._center_x_ratio,
        center_y_ratio   = self._center_y_ratio,
    }
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = img_h },
        self._image_wg,
    }
end

function PinnedImageViewer:_clean_image_wg()
    if self._image_wg then
        self._image_wg:free()
        self._image_wg = nil
    end
end

-- Barra de nav con ButtonTable: cada celda tiene borde separado (igual que nativo)
-- Devuelve (nav_table, nav_container) para poder liberarlos en onCloseWidget
function PinnedImageViewer:_buildNavBar(sw)
    local idx = self.index
    local tot = self.total

    local nav_buttons = {{
        {
            text     = "◀◀◀",
            enabled  = idx > 1,
            callback = function() self:_nav(1) end,
        },
        {
            text     = "◀",
            enabled  = idx > 1,
            callback = function() self:_nav(idx - 1) end,
        },
        {
            text    = T(_("%1 de %2"), idx, tot),
            enabled = false,   -- solo display, no tappable
        },
        {
            text     = "▶",
            enabled  = idx < tot,
            callback = function() self:_nav(idx + 1) end,
        },
        {
            text     = "▶▶▶",
            enabled  = idx < tot,
            callback = function() self:_nav(tot) end,
        },
    }}

    local nav_table = ButtonTable:new{
        width       = sw - 2 * self.button_padding,
        buttons     = nav_buttons,
        zero_sep    = true,
        show_parent = self,
    }
    local nav_container = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = nav_table:getSize().h },
        nav_table,
    }
    return nav_table, nav_container
end

function PinnedImageViewer:_nav(target)
    UIManager:close(self)
    if self.onNavigate then self.onNavigate(target) end
end

-- ── Eventos del ciclo de vida ──────────────────────────────────────────────────

function PinnedImageViewer:onShow()
    self.dithered = true
    UIManager:setDirty(self, function()
        return "full", self.main_frame.dimen, true
    end)
    return true
end

function PinnedImageViewer:onClose()
    UIManager:close(self)
    return true
end

function PinnedImageViewer:onCloseWidget()
    self:_clean_image_wg()
    self.title_bar:free()
    self.button_container:free()
    if self.nav_table then self.nav_container:free() end
    UIManager:setDirty(nil, function()
        return "flashui", self.main_frame.dimen
    end)
end

-- ── Gestos táctiles (fieles a ImageViewer) ────────────────────────────────────

function PinnedImageViewer:onTap(_, ges)
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        -- Consumimos el gesto sin cerrar la ventana
        return true
    end
    -- Tap dentro del popup: TitleBar gestiona su zona; resto no hace nada
    return true
end

function PinnedImageViewer:panBy(x, y)
    if self._image_wg then
        self._center_x_ratio, self._center_y_ratio = self._image_wg:panBy(x, y)
    end
end

function PinnedImageViewer:onHold(_, ges)
    self._panning        = true
    self._pan_relative_x = ges.pos.x
    self._pan_relative_y = ges.pos.y
    return true
end

function PinnedImageViewer:onHoldRelease(_, ges)
    if self._panning then
        self._panning = false
        local dx = ges.pos.x - self._pan_relative_x
        local dy = ges.pos.y - self._pan_relative_y
        if math.abs(dx) < self.pan_threshold and math.abs(dy) < self.pan_threshold then
            -- Hold sin movimiento → refresco completo
            self.dithered = true
            UIManager:setDirty(nil, "full", nil, true)
        else
            self:panBy(-dx, -dy)
        end
    end
    return true
end

function PinnedImageViewer:onPan(_, ges)
    self._panning        = true
    self._pan_relative_x = ges.relative.x
    self._pan_relative_y = ges.relative.y
    return true
end

function PinnedImageViewer:onPanRelease(_, ges)
    if self._panning then
        self._panning = false
        self:panBy(-self._pan_relative_x, -self._pan_relative_y)
    end
    return true
end

function PinnedImageViewer:onSwipe(_, ges)
    if not self._image_wg then return end
    local dir      = ges.direction
    local dist     = ges.distance
    local sq_d     = math.sqrt(dist * dist / 2)
    local sw       = Screen:getWidth()
    local sh       = Screen:getHeight()
    if dir == "north" then
        if ges.pos.x < sw / 8 or ges.pos.x > sw * 7 / 8 then
            self:onZoomIn(dist / math.min(sh, self._image_wg:getCurrentHeight()))
        else
            self:panBy(0, dist)
        end
    elseif dir == "south" then
        if ges.pos.x < sw / 8 or ges.pos.x > sw * 7 / 8 then
            self:onZoomOut(dist / math.min(sh, self._image_wg:getCurrentHeight()))
        elseif self.scale_factor == 0 then
            self:onClose()
        else
            self:panBy(0, -dist)
        end
    elseif dir == "east"      then self:panBy(-dist,  0)
    elseif dir == "west"      then self:panBy( dist,  0)
    elseif dir == "northeast" then self:panBy(-sq_d,  sq_d)
    elseif dir == "northwest" then self:panBy( sq_d,  sq_d)
    elseif dir == "southeast" then self:panBy(-sq_d, -sq_d)
    elseif dir == "southwest" then self:panBy( sq_d, -sq_d)
    end
    return true
end

function PinnedImageViewer:onMultiSwipe()
    self:onClose()
    return true
end

-- ── Zoom (igual que ImageViewer) ──────────────────────────────────────────────

function PinnedImageViewer:_refreshScaleFactor()
    if self.scale_factor == 0 then
        self.scale_factor = self._scale_factor_0 or self._image_wg:getScaleFactor()
    end
end

function PinnedImageViewer:_applyNewScaleFactor(new_factor)
    self:_refreshScaleFactor()
    if not self._min_scale_factor or not self._max_scale_factor then
        self._min_scale_factor, self._max_scale_factor =
            self._image_wg:getScaleFactorExtrema()
    end
    new_factor = math.min(new_factor, self._max_scale_factor)
    new_factor = math.max(new_factor, self._min_scale_factor)
    if new_factor ~= self.scale_factor then
        self.scale_factor = new_factor
        self:update()
    end
end

function PinnedImageViewer:onZoomIn(inc)
    self:_refreshScaleFactor()
    inc = inc or 0.2
    self:_applyNewScaleFactor(self.scale_factor * (1 + inc))
    return true
end

function PinnedImageViewer:onZoomOut(dec)
    self:_refreshScaleFactor()
    dec = dec or 0.2
    if dec >= 0.75 then dec = 0.75 end
    self:_applyNewScaleFactor(self.scale_factor * (1 - dec))
    return true
end

function PinnedImageViewer:onSpread(_, ges)
    if not self._image_wg then return end
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._center_x_ratio, self._center_y_ratio =
        self._image_wg:getPanByCenterRatio(ges.pos.x - sw / 2, ges.pos.y - sh / 2)
    if ges.direction == "vertical" then
        self:onZoomIn(ges.distance / math.min(sh, self._image_wg:getCurrentHeight()))
    elseif ges.direction == "horizontal" then
        self:onZoomIn(ges.distance / math.min(sw, self._image_wg:getCurrentWidth()))
    else
        local sd = math.sqrt(sw ^ 2 + sh ^ 2)
        self:onZoomIn(ges.distance / math.min(sd, self._image_wg:getCurrentDiagonal()))
    end
    return true
end

function PinnedImageViewer:onPinch(_, ges)
    if not self._image_wg then return end
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    if ges.direction == "vertical" then
        self:onZoomOut(ges.distance / math.min(sh, self._image_wg:getCurrentHeight()))
    elseif ges.direction == "horizontal" then
        self:onZoomOut(ges.distance / math.min(sw, self._image_wg:getCurrentWidth()))
    else
        local sd = math.sqrt(sw ^ 2 + sh ^ 2)
        self:onZoomOut(ges.distance / math.min(sd, self._image_wg:getCurrentDiagonal()))
    end
    return true
end

local pinned_text_size      = 16    -- Tamaño base (coincide con FACE_MAIN)
local pinned_text_alignment = "left" -- Ciclo: "left" → "center" → "right" → "justify"

-- Tabla de ciclo y etiquetas para el botón de alineación
local ALIGN_CYCLE = { "left", "center", "right", "justify" }
local ALIGN_LABEL = {
    left    = _("Alinear: ◀ Izquierda"),
    center  = _("Alinear: ≡ Centro"),
    right   = _("Alinear: ▶ Derecha"),
    justify = _("Alinear: ☰ Justificado"),
}

local function nextAlignment(cur)
    for i, v in ipairs(ALIGN_CYCLE) do
        if v == cur then
            return ALIGN_CYCLE[(i % #ALIGN_CYCLE) + 1]
        end
    end
    return "left"
end

-- ── PinnedTextViewer ─────────────────────────────────────────────────────────
-- Visor de texto personalizado con menú hamburguesa, título centrado,
-- navegación inferior y opción de copiar al portapapeles.

local PinnedTextViewer = InputContainer:extend{
    pin             = nil,
    index           = nil,
    total           = nil,
    onNavigate      = nil,
    onGotoPage      = nil,
    popup           = nil,
    _sw             = nil,
    _sh             = nil,
    text_padding    = Size.padding.default * 2,
}

function PinnedTextViewer:init()
    updateDimensions()
    local sw = POPUP_W
    local sh = POPUP_H
    self._sw = sw
    self._sh = sh
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    -- Registrar botones físicos para zoom
    if Device:hasKeys() then
        self.key_events = {
            Close   = { { Device.input.group.Back } },
            ZoomIn  = { { Device.input.group.PgBack } },
            ZoomOut = { { Device.input.group.PgFwd } },
        }
    end

    -- Registrar gestos táctiles
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.ges_events = {
            Tap    = { GestureRange:new{ ges = "tap",    range = range } },
            Spread = { GestureRange:new{ ges = "spread", range = range } },
            Pinch  = { GestureRange:new{ ges = "pinch",  range = range } },
            Swipe  = { GestureRange:new{ ges = "swipe",  range = range } },
        }
    end

    self.frame_elements = VerticalGroup:new{ align = "left" }
    self.main_frame = FrameContainer:new{
        radius     = 8,
        padding    = 0,
        margin     = 0,
        bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        self.frame_elements,
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.main_frame,
    }

    self:update()
end

function PinnedTextViewer:update()
    local sw = self._sw
    local sh = self._sh
    local orig_dimen = self.main_frame.dimen

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    -- 1) TitleBar con icono izquierdo y cierre normal
    self.title_bar = TitleBar:new{
        width            = sw,
        title            = self.pin.label,
        title_multilines = true,
        with_bottom_line = true,
        left_icon        = "appbar.menu",
        left_icon_tap_callback = function() self:_showMenu() end,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }
    table.insert(self.frame_elements, self.title_bar)

    -- 2) Generar barra de navegación inferior estática
    self.nav_table, self.nav_container = self:_buildNavBar(sw)

    -- Calcular altura libre restante para el cuerpo de texto
    local fixed_h = self.title_bar:getSize().h + self.nav_container:getSize().h + Size.line.thin
    local text_h  = sh - fixed_h

    -- 3) Área de texto principal.
    -- Usamos TextBoxWidget directamente sin ScrollableContainer para evitar
    -- la barra de desplazamiento horizontal que aparece cuando el scrollbar
    -- vertical reserva píxeles y hace que el texto desborde horizontalmente.
    -- El scroll vertical se maneja con swipe norte/sur via onSwipe().
    local text_widget = TextBoxWidget:new{
        text      = self.pin.text or self.pin.label,
        width     = sw - self.text_padding * 2,
        height    = text_h,
        face      = Font:getFace("cfont", pinned_text_size),
        alignment = pinned_text_alignment,
    }
    self._text_widget = text_widget  -- referencia para onSwipe

    self.text_container = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = text_h },
        text_widget,
    }

    table.insert(self.frame_elements, self.text_container)
    table.insert(self.frame_elements, LineWidget:new{ dimen = Geom:new{ w = sw, h = Size.line.thin } })
    table.insert(self.frame_elements, self.nav_container)

    self.frame_elements:resetLayout()

    self.dithered = true
    UIManager:setDirty(self, function()
        return "ui", self.main_frame.dimen:combine(orig_dimen or self.main_frame.dimen), true
    end)
end

function PinnedTextViewer:_buildNavBar(sw)
    local idx = self.index
    local tot = self.total

    local nav_buttons = {{
        {
            text     = "◀◀◀",
            enabled  = idx > 1,
            callback = function() self:_nav(1) end,
        },
        {
            text     = "◀",
            enabled  = idx > 1,
            callback = function() self:_nav(idx - 1) end,
        },
        {
            text    = T(_("%1 de %2"), idx, tot),
            enabled = false,
        },
        {
            text     = "▶",
            enabled  = idx < tot,
            callback = function() self:_nav(idx + 1) end,
        },
        {
            text     = "▶▶▶",
            enabled  = idx < tot,
            callback = function() self:_nav(tot) end,
        },
    }}

    local nav_table = ButtonTable:new{
        width       = sw - 2 * Size.padding.default,
        buttons     = nav_buttons,
        zero_sep    = true,
        show_parent = self,
    }
    local nav_container = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = nav_table:getSize().h },
        nav_table,
    }
    return nav_table, nav_container
end

function PinnedTextViewer:_nav(target)
    UIManager:close(self)
    if self.onNavigate then self.onNavigate(target) end
end

function PinnedTextViewer:_showMenu()
    local dialog
    dialog = ButtonDialog:new{
        title   = self.pin.label,
        buttons = {
            {{
                text     = _("Renombrar texto"),
                callback = function()
                    UIManager:close(dialog)
                    
                    local input_dialog
                    input_dialog = InputDialog:new{
                        title = _("Renombrar texto fijado"),
                        input = self.pin.label,
                        buttons = {{
                            {
                                text = _("Cancelar"),
                                callback = function() UIManager:close(input_dialog) end,
                            },
                            {
                                text = _("Aceptar"),
                                callback = function()
                                    local new_text = input_dialog:getInputValue()
                                    if new_text and new_text ~= "" then
                                        self.pin.label = new_text
                                        self:update()
                                        if self.popup then
                                            self.popup:_build()
                                            UIManager:setDirty(self.popup, "ui")
                                        end
                                    end
                                    UIManager:close(input_dialog)
                                end,
                            },
                        }}
                    }
                    UIManager:show(input_dialog)
                end,
            }},
            {{
                text     = _("Ir a la página"),
                callback = function()
                    UIManager:close(dialog)
                    self:onClose()
                    if self.onGotoPage then self.onGotoPage(self.pin.page) end
                end,
            }},
            {{
                text     = _("Cambiar tamaño de letra"),
                callback = function()
                    UIManager:close(dialog) -- Cierra el menú principal
                    
                    -- Función recursiva para reconstruir el menú con el nuevo número
                    local function showSizeDialog()
                        local size_dialog
                        size_dialog = ButtonDialog:new{
                            title   = _("Ajustar tamaño de letra"),
                            buttons = {
                                {{
                                    text = " - ",
                                    callback = function()
                                        pinned_text_size = math.max(10, pinned_text_size - 2)
                                        self:update() -- Refresca el texto de fondo
                                        UIManager:close(size_dialog) -- Cierra el cuadro actual
                                        showSizeDialog() -- Lo reabre con el número actualizado
                                    end,
                                },
                                {
                                    text    = tostring(pinned_text_size),
                                    enabled = false, -- Solo visualización
                                },
                                {
                                    text = " + ",
                                    callback = function()
                                        pinned_text_size = pinned_text_size + 2
                                        self:update() -- Refresca el texto de fondo
                                        UIManager:close(size_dialog) -- Cierra el cuadro actual
                                        showSizeDialog() -- Lo reabre con el número actualizado
                                    end,
                                }},
                                {{
                                    text = _("Cerrar"),
                                    callback = function() UIManager:close(size_dialog) end,
                                }}
                            }
                        }
                        UIManager:show(size_dialog)
                    end
                    
                    showSizeDialog() -- Llama a la función por primera vez
                end,
            }},
            {{
                text     = ALIGN_LABEL[pinned_text_alignment] or ALIGN_LABEL["left"],
                callback = function()
                    UIManager:close(dialog)
                    pinned_text_alignment = nextAlignment(pinned_text_alignment)
                    self:update()
                end,
            }},
            {{
                text     = _("Copiar al portapapeles"),
                callback = function()
                    UIManager:close(dialog)
                    local text_to_copy = self.pin.text or self.pin.label
                    
                    if Device:hasClipboard() then
                        Device.input.setClipboardText(text_to_copy)
                        local Notification = require("ui/widget/notification")
                        UIManager:show(Notification:new{
                            text = _("Texto copiado al portapapeles"),
                        })
                    end
                end,
            }},
            {{
                text     = _("Cancelar"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function PinnedTextViewer:onClose()
    UIManager:close(self)
    return true
end

function PinnedTextViewer:onTap(_, ges)
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        return true
    end
    return true
end

function PinnedTextViewer:onSwipe(_, ges)
    if not self._text_widget then return end
    local dir = ges.direction
    if dir == "north" or dir == "left" then
        -- Deslizar hacia arriba / izquierda → siguiente página de texto
        if self._text_widget:scrollDown() then
            UIManager:setDirty(self, "ui")
        end
    elseif dir == "south" or dir == "right" then
        -- Deslizar hacia abajo / derecha → página anterior
        if self._text_widget:scrollUp() then
            UIManager:setDirty(self, "ui")
        end
    end
    return true
end

function PinnedTextViewer:onZoomIn()
    pinned_text_size = pinned_text_size + 2
    self:update()
    return true
end

function PinnedTextViewer:onZoomOut()
    pinned_text_size = math.max(10, pinned_text_size - 2)
    self:update()
    return true
end

function PinnedTextViewer:onSpread()
    return self:onZoomIn()
end

function PinnedTextViewer:onPinch()
    return self:onZoomOut()
end

-- ── PinItem ───────────────────────────────────────────────────────────────────

local PinItem = InputContainer:extend{
    pin        = nil,
    popup      = nil,
    item_w     = nil,
    item_index = nil,
}

function PinItem:init()
    self.dimen = Geom:new{ w = self.item_w, h = ITEM_H }

    local thumb
    if self.pin.img_path and lfs.attributes(self.pin.img_path, "mode") == "file" then
        thumb = FrameContainer:new{
            padding = 0, bordersize = 1,
            ImageWidget:new{
                file         = self.pin.img_path,
                width        = THUMB_SIZE,
                height       = THUMB_SIZE,
                scale_factor = 0,
            },
        }
    else
        local icon = self.pin.type == "text" and "T" or "#"
        thumb = FrameContainer:new{
            padding = 0, bordersize = 1,
            width   = THUMB_SIZE,
            height  = THUMB_SIZE,
            CenterContainer:new{
                dimen = Geom:new{ w = THUMB_SIZE, h = THUMB_SIZE },
                TextWidget:new{ text = icon, face = FACE_ICON },
            },
        }
    end

    local info_w = self.item_w - THUMB_SIZE - PAD * 4

    local label  = TextBoxWidget:new{
        text  = self.pin.label,
        width = info_w,
        face  = FACE_MAIN,
    }

    local elements_list = { label, VerticalSpan:new{ width = 4 } }

    -- Si es un pin de texto y el título es distinto al texto original, mostramos la descripción
    if self.pin.type == "text" and self.pin.text and self.pin.text ~= self.pin.label then
        local desc = TextWidget:new{
            text      = self.pin.text:gsub("\n", " "), -- Muestra el texto en una sola línea
            max_width = info_w,
            face      = FACE_SUB,
            fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(elements_list, desc)
        table.insert(elements_list, VerticalSpan:new{ width = 4 })
    end

    local pinfo = TextWidget:new{
        text = T(_("p. %1"), tostring(self.pin.page)),
        face = FACE_SUB,
    }
    table.insert(elements_list, pinfo)

    self[1] = HorizontalGroup:new{
        HorizontalSpan:new{ width = PAD },
        thumb,
        HorizontalSpan:new{ width = PAD },
        LeftContainer:new{
            dimen = Geom:new{ w = info_w, h = ITEM_H },
            VerticalGroup:new{
                align = "left",
                unpack(elements_list)
            },
        },
    }

    self.ges_events.Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } }
    self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = self.dimen } }
end

-- Tap: abre el visor con navegación
function PinItem:onTap()
    self.popup:_openPinAtIndex(self.item_index)
    return true
end

-- Hold: menú con opciones adicionales
function PinItem:onHold()
    local pin      = self.pin
    local popup    = self.popup
    local has_file = pin.img_path and lfs.attributes(pin.img_path, "mode") == "file"

    local dialog
    dialog = ButtonDialog:new{
        title   = pin.label,
        buttons = {
            {{
                text     = _("Renombrar"),
                callback = function()
                    UIManager:close(dialog) -- Cierra el menú principal
                    
                    local input_dialog
                    input_dialog = InputDialog:new{
                        title = _("Renombrar elemento"),
                        input = pin.label,
                        buttons = {{
                            {
                                text = _("Cancelar"),
                                callback = function()
                                    UIManager:close(input_dialog)
                                end,
                            },
                            {
                                text = _("Aceptar"),
                                callback = function()
                                    local new_text = input_dialog:getInputValue()
                                    if new_text and new_text ~= "" then
                                        pin.label = new_text
                                        popup:_build()
                                        UIManager:setDirty(popup, "ui")
                                    end
                                    UIManager:close(input_dialog)
                                end,
                            },
                        }}
                    }
                    UIManager:show(input_dialog)
                end,
            }},
            {{
                text     = _("Go to page"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:close(popup)
                    if popup.onGotoPage then popup.onGotoPage(pin.page) end
                end,
            }},
            {{
                text     = _("View image"),
                enabled  = has_file and true or false,
                callback = function()
                    UIManager:close(dialog)
                    local ImageViewer = require("ui/widget/imageviewer")
                    UIManager:show(ImageViewer:new{
                        file           = pin.img_path,
                        with_title_bar = true,
                        title_text     = pin.label,
                    })
                end,
            }},
            {{
                text     = _("Delete pin"),
                callback = function()
                    UIManager:close(dialog)
                    if popup.onDeletePin then popup.onDeletePin(pin.id) end
                    popup:_sortPins()
                    popup:_build()
                    UIManager:setDirty(popup, "ui")
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
    return true
end

-- ── PinnedPopup ───────────────────────────────────────────────────────────────

local PinnedPopup = InputContainer:extend{
    pins         = nil,
    onGotoPage   = nil,
    onDeletePin  = nil,
    _frame       = nil,
    cur_page     = 1,
    _sort_order  = "created",
    _sorted_pins = nil,
}

function PinnedPopup:init()
    updateDimensions()
    self.cur_page = 1
    self:_sortPins()
    self:_build()
    self.ges_events.TapOutside = {
        GestureRange:new{ ges = "tap", range = Screen:getSize() },
    }
end

function PinnedPopup:onTapOutside(ges)
    if not ges or not ges.pos then return false end
    local fd = self._frame and self._frame.dimen
    if fd and not fd:contains(ges.pos) then
        UIManager:close(self)
    end
    return true
end

-- ── Ordenamiento ──────────────────────────────────────────────────────────────

function PinnedPopup:_sortPins()
    self._sorted_pins = {}
    for _, p in ipairs(self.pins or {}) do
        table.insert(self._sorted_pins, p)
    end
    if self._sort_order == "page" then
        table.sort(self._sorted_pins, function(a, b)
            if a.page ~= b.page then return a.page < b.page end
            return (a.created or 0) < (b.created or 0)
        end)
    else
        table.sort(self._sorted_pins, function(a, b)
            return (a.created or 0) < (b.created or 0)
        end)
    end
end

function PinnedPopup:_showSortMenu()
    local popup = self
    local dialog
    dialog = ButtonDialog:new{
        title   = _("Sort order"),
        buttons = {
            {{
                text     = _("By page (first to last)"),
                callback = function()
                    UIManager:close(dialog)
                    popup._sort_order = "page"
                    popup:_sortPins()
                    popup.cur_page = 1
                    popup:_build()
                    UIManager:setDirty(popup, "ui")
                end,
            }},
            {{
                text     = _("By pin order (oldest first)"),
                callback = function()
                    UIManager:close(dialog)
                    popup._sort_order = "created"
                    popup:_sortPins()
                    popup.cur_page = 1
                    popup:_build()
                    UIManager:setDirty(popup, "ui")
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- ── Navegación de lista ───────────────────────────────────────────────────────

function PinnedPopup:_goToPage(page_num, total_pages)
    page_num = math.max(1, math.min(total_pages, page_num))
    if page_num == self.cur_page then return end
    self.cur_page = page_num
    self:_build()
    UIManager:setDirty(self, "ui")
end

-- ── Visor con navegación entre pins ──────────────────────────────────────────
--
-- Para texto:  abre TextViewer nativo con buttons_table de navegación.
-- Para imagen: abre PinnedImageViewer (visor propio, siempre muestra nav bar).
-- Para página: navega directamente al libro.

function PinnedPopup:_openPinAtIndex(index)
    local sorted = self._sorted_pins or {}
    local total  = #sorted
    if index < 1 or index > total then return end

    local pin   = sorted[index]
    local popup = self

    -- Función de navegación compartida entre TextViewer y PinnedImageViewer
    local function navigateTo(target)
        popup:_openPinAtIndex(target)
    end

    if pin.type == "text" then
        UIManager:show(PinnedTextViewer:new{
            pin        = pin,
            index      = index,
            total      = total,
            popup      = popup,
            onNavigate = navigateTo,
            onGotoPage = function(page)
                UIManager:close(popup)
                if popup.onGotoPage then popup.onGotoPage(page) end
            end,
        })

    elseif pin.type == "image"
       and pin.img_path
       and lfs.attributes(pin.img_path, "mode") == "file" then
        -- PinnedImageViewer: visor propio que SIEMPRE muestra la barra de nav
        UIManager:show(PinnedImageViewer:new{
            pin        = pin,
            index      = index,
            total      = total,
            onNavigate = navigateTo,
            onGotoPage = function(page)
                UIManager:close(popup)
                if popup.onGotoPage then popup.onGotoPage(page) end
            end,
        })

    else
        -- pin de página: cerrar popup y navegar
        UIManager:close(popup)
        if popup.onGotoPage then popup.onGotoPage(pin.page) end
    end
end

-- ── Construcción del widget ───────────────────────────────────────────────────

function PinnedPopup:_build()
    local title_bar = TitleBar:new{
        width                  = POPUP_W,
        title                  = _("Pinned Elements"),
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:_showSortMenu() end,
        close_callback         = function() UIManager:close(self) end,
    }

    local content_h = POPUP_H - BAR_H - NAV_H - Size.line.thin

    local sorted      = self._sorted_pins or {}
    local total       = #sorted
    local page_size   = math.max(1, math.floor(content_h / ITEM_H))
    local total_pages = math.max(1, math.ceil(total / page_size))

    if self.cur_page > total_pages then self.cur_page = total_pages end
    if self.cur_page < 1           then self.cur_page = 1          end

    local list = VerticalGroup:new{ align = "left" }

    if total == 0 then
        table.insert(list, CenterContainer:new{
            dimen = Geom:new{ w = POPUP_W, h = content_h },
            TextBoxWidget:new{
                text      = _("No pinned elements.\n\nSelect text -> 'Pin text',\nor Long press an Image -> 'Pin Image',\nor Take a Screenshot -> 'Pin Image'."),
                width     = POPUP_W - PAD * 6,
                face      = FACE_SUB,
                alignment = "center",
            },
        })
    else
        local start_i = (self.cur_page - 1) * page_size + 1
        local end_i   = math.min(start_i + page_size - 1, total)

        for i = start_i, end_i do
            table.insert(list, PinItem:new{
                pin        = sorted[i],
                popup      = self,
                item_w     = POPUP_W,
                item_index = i,
            })
            if i < end_i then
                table.insert(list, LineWidget:new{
                    dimen = Geom:new{ w = POPUP_W, h = Size.line.thin },
                })
            end
        end

        local shown  = end_i - start_i + 1
        local fill_h = content_h - shown * ITEM_H - (shown - 1) * Size.line.thin
        if fill_h > 0 then
            table.insert(list, VerticalSpan:new{ width = fill_h })
        end
    end

    -- Barra de paginación de la lista
    local nav_btn_w   = math.floor(POPUP_W * 0.14)
    local nav_label_w = POPUP_W - nav_btn_w * 4
    local has_pins    = total > 0
    local not_first   = self.cur_page > 1
    local not_last    = self.cur_page < total_pages

    local nav_bar = CenterContainer:new{
        dimen = Geom:new{ w = POPUP_W, h = NAV_H },
        HorizontalGroup:new{
            NavButton:new{
                label_text = "◀◀◀",
                width      = nav_btn_w,
                enabled    = has_pins and not_first,
                callback   = function() self:_goToPage(1, total_pages) end,
            },
            NavButton:new{
                label_text = "◀",
                width      = nav_btn_w,
                enabled    = has_pins and not_first,
                callback   = function() self:_goToPage(self.cur_page - 1, total_pages) end,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = nav_label_w, h = NAV_H },
                TextWidget:new{
                    text = T(_("%1 / %2"), self.cur_page, total_pages),
                    face = FACE_SUB,
                },
            },
            NavButton:new{
                label_text = "▶",
                width      = nav_btn_w,
                enabled    = has_pins and not_last,
                callback   = function() self:_goToPage(self.cur_page + 1, total_pages) end,
            },
            NavButton:new{
                label_text = "▶▶▶",
                width      = nav_btn_w,
                enabled    = has_pins and not_last,
                callback   = function() self:_goToPage(total_pages, total_pages) end,
            },
        },
    }

    self._frame = FrameContainer:new{
        width      = POPUP_W,
        padding    = 0,
        margin     = 0,
        bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            title_bar,
            list,
            LineWidget:new{ dimen = Geom:new{ w = POPUP_W, h = Size.line.thin } },
            nav_bar,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self._frame,
    }
end

return PinnedPopup