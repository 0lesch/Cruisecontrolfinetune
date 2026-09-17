--[[
    CruiseControlFineTune.lua
    Version 7.0.0.0 - Autor: Ole_sch

    Zwei Tasten (Standard: SHIFT+2 = erhöhen, SHIFT+1 = verringern; frei
    über die Spieleinstellungen änderbar), die die Tempomat-Geschwindigkeit
    des aktuell gesteuerten Fahrzeugs in 0,1-Schritten DER AKTUELL
    EINGESTELLTEN ANZEIGEEINHEIT (km/h oder mph) anpassen, ausgehend vom
    aktuell eingestellten Wert. Schaltet den Tempomat selbst nicht ein/aus.
]]

CruiseControlFineTune = {}
CruiseControlFineTune.STEP = 0.1
CruiseControlFineTune.MIN_SPEED = 1.0 -- Native Fahrzeug-Untergrenze (spec.cruiseControl.minSpeed) klemmt ohnehin zusätzlich, falls sie höher liegt
CruiseControlFineTune.MAX_SPEED = 300 -- Fallback, falls vehicle:getCruiseControlMaxSpeed() nicht verfügbar ist (siehe adjustSpeed)
CruiseControlFineTune.DEBUG = false -- per Konsolenbefehl "ccftDebugToggle" umschaltbar

-- ============================================================================
-- Eigenes Multiplayer-Sync-Event (volle Nachkommastellen-Genauigkeit)
-- ============================================================================
-- Das native SetCruiseControlSpeedEvent des Spiels überträgt die
-- Geschwindigkeit nur als GANZE ZAHL (der native Tempomat kennt keine
-- Nachkommastellen) - dadurch würde unser Feinwert beim Senden gerundet.
-- Dieses eigene Event überträgt den Wert stattdessen als Float32 (volle
-- Genauigkeit) und wendet ihn beim Empfänger einfach über das normale
-- vehicle:setCruiseControlMaxSpeed() an (das selbst kein Event verschickt,
-- siehe echter Drivable.lua-Quellcode - daher keine Endlosschleife).
CCFTSetSpeedEvent = {}
local CCFTSetSpeedEvent_mt = Class(CCFTSetSpeedEvent, Event)
InitEventClass(CCFTSetSpeedEvent, "CCFTSetSpeedEvent")

function CCFTSetSpeedEvent.emptyNew()
    return Event.new(CCFTSetSpeedEvent_mt)
end

function CCFTSetSpeedEvent.new(vehicle, speed)
    local self = CCFTSetSpeedEvent.emptyNew()
    self.vehicle = vehicle
    self.speed = speed
    return self
end

function CCFTSetSpeedEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.speed = streamReadFloat32(streamId)
    self:run(connection)
end

function CCFTSetSpeedEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteFloat32(streamId, self.speed)
end

function CCFTSetSpeedEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle.setCruiseControlMaxSpeed ~= nil then
        self.vehicle:setCruiseControlMaxSpeed(self.speed)
    end
    if not connection:getIsServer() then
        -- Wir sind der Server: an alle anderen Clients weiterreichen.
        g_server:broadcastEvent(CCFTSetSpeedEvent.new(self.vehicle, self.speed), nil, connection, self.vehicle)
    end
end

function CCFTSetSpeedEvent.sendEvent(vehicle, speed)
    if g_server ~= nil then
        g_server:broadcastEvent(CCFTSetSpeedEvent.new(vehicle, speed), nil, nil, vehicle)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(CCFTSetSpeedEvent.new(vehicle, speed))
    end
end

-- ============================================================================
-- Tastenregistrierung (fahrzeugspezifisch über Drivable:onRegisterActionEvents)
-- ============================================================================
function CruiseControlFineTune.onVehicleRegisterActionEvents(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    if not vehicle.isClient or vehicle.spec_drivable == nil then
        return
    end
    if vehicle.addActionEvent == nil or vehicle.clearActionEventsTable == nil then
        return
    end

    vehicle.ccftActionEvents = vehicle.ccftActionEvents or {}
    vehicle:clearActionEventsTable(vehicle.ccftActionEvents)

    if vehicle:getIsActiveForInput(true, true) and InputAction ~= nil then
        if InputAction.CCFT_INC ~= nil then
            local _, eventId1 = vehicle:addActionEvent(vehicle.ccftActionEvents, InputAction.CCFT_INC,
                CruiseControlFineTune, CruiseControlFineTune.onSpeedUp, false, true, false, true, nil)
            if eventId1 ~= nil then
                g_inputBinding:setActionEventTextVisibility(eventId1, false)
            end
        end
        if InputAction.CCFT_DEC ~= nil then
            local _, eventId2 = vehicle:addActionEvent(vehicle.ccftActionEvents, InputAction.CCFT_DEC,
                CruiseControlFineTune, CruiseControlFineTune.onSpeedDown, false, true, false, true, nil)
            if eventId2 ~= nil then
                g_inputBinding:setActionEventTextVisibility(eventId2, false)
            end
        end
    end
end

if Drivable ~= nil and Drivable.onRegisterActionEvents ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    Drivable.onRegisterActionEvents = Utils.appendedFunction(Drivable.onRegisterActionEvents, CruiseControlFineTune.onVehicleRegisterActionEvents)
    print("[CruiseControlFineTune] An Drivable:onRegisterActionEvents angehängt.")
else
    print("[CruiseControlFineTune] FEHLER: Drivable.onRegisterActionEvents oder Utils.appendedFunction nicht gefunden.")
end

-- ============================================================================
-- Kernlogik
-- ============================================================================
function CruiseControlFineTune:getCurrentlyControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local vehicle = g_localPlayer:getCurrentVehicle()
        if vehicle ~= nil then
            return vehicle
        end
    end
    if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
        return g_currentMission.controlledVehicle
    end
    return nil
end

function CruiseControlFineTune:isUsingMiles()
    if g_gameSettings ~= nil and g_gameSettings.getValue ~= nil then
        return g_gameSettings:getValue("useMiles") == true
    end
    return false
end

CruiseControlFineTune.MPH_TO_KMH = 1.609344

function CruiseControlFineTune:toDisplayUnit(speedKmh)
    if self:isUsingMiles() then
        return speedKmh / self.MPH_TO_KMH
    end
    return speedKmh
end

function CruiseControlFineTune:fromDisplayUnit(speedDisplay)
    if self:isUsingMiles() then
        -- Kleiner Sicherheitsaufschlag (0,0005 km/h - weit unterhalb der
        -- angezeigten Auflösung von 0,1 mph) gegen Gleitkomma-Rundungsfehler:
        -- ohne ihn kann z.B. exakt 9,0 mph intern zu 8.999999999999998 km/h
        -- werden, was das native Spiel beim Anzeigen offenbar abschneidet
        -- statt zu runden - dadurch würde "8" statt "9" angezeigt.
        return speedDisplay * self.MPH_TO_KMH + 0.0005
    end
    return speedDisplay
end

function CruiseControlFineTune:applyNewSpeed(vehicle, baseSpeed, newSpeed)
    -- Obergrenze dynamisch vom Fahrzeug (nicht hartkodiert)
    local maxSpeed = self.MAX_SPEED
    if vehicle.getCruiseControlMaxSpeed ~= nil then
        local vehicleMaxSpeed = vehicle:getCruiseControlMaxSpeed()
        if vehicleMaxSpeed ~= nil and vehicleMaxSpeed > 0 then
            maxSpeed = vehicleMaxSpeed
        end
    end

    if newSpeed < self.MIN_SPEED then
        newSpeed = self.MIN_SPEED
    elseif newSpeed > maxSpeed then
        newSpeed = maxSpeed
    end

    vehicle:setCruiseControlMaxSpeed(newSpeed)

    -- Multiplayer-Sync mit voller Genauigkeit (siehe CCFTSetSpeedEvent
    -- oben). Das native SetCruiseControlSpeedEvent würde hier auf eine
    -- ganze Zahl runden.
    CCFTSetSpeedEvent.sendEvent(vehicle, newSpeed)

    if self.DEBUG then
        print(string.format("[CruiseControlFineTune] Tempomat-Geschwindigkeit: %.4f -> %.4f km/h (Obergrenze: %.1f)", baseSpeed, newSpeed, maxSpeed))
    end
end

-- Für den Konsolenbefehl: roher km/h-Delta, unabhängig von der Einheit.
function CruiseControlFineTune:adjustSpeed(delta)
    local vehicle = self:getCurrentlyControlledVehicle()
    if vehicle == nil then
        if self.DEBUG then print("[CruiseControlFineTune] Kein Fahrzeug gesteuert.") end
        return
    end
    if vehicle.getCruiseControlSpeed == nil or vehicle.setCruiseControlMaxSpeed == nil then
        if self.DEBUG then print("[CruiseControlFineTune] Fahrzeug unterstützt keinen Tempomat.") end
        return
    end

    local baseSpeed = vehicle:getCruiseControlSpeed() or 0
    local newSpeed = math.floor((baseSpeed + delta) * 10 + 0.5) / 10
    self:applyNewSpeed(vehicle, baseSpeed, newSpeed)
end

-- Für die Tasten: Schritt UND Rundung erfolgen komplett in der gerade
-- angezeigten Einheit (km/h oder mph). Dadurch ist die Umrechnung 1,609344
-- für die Sprunggröße irrelevant - ein Tastendruck ändert immer sauber
-- 0,1 der angezeigten Einheit, ohne krumme Zwischenwerte beim Runden auf
-- km/h. Umrechnung nach km/h erfolgt erst ganz am Ende, ohne erneutes
-- Runden (das würde die glatte Anzeige-Nachkommastelle wieder zerstören).
function CruiseControlFineTune:adjustSpeedByDisplayStep(direction)
    local vehicle = self:getCurrentlyControlledVehicle()
    if vehicle == nil then
        if self.DEBUG then print("[CruiseControlFineTune] Kein Fahrzeug gesteuert.") end
        return
    end
    if vehicle.getCruiseControlSpeed == nil or vehicle.setCruiseControlMaxSpeed == nil then
        if self.DEBUG then print("[CruiseControlFineTune] Fahrzeug unterstützt keinen Tempomat.") end
        return
    end

    local baseSpeedKmh = vehicle:getCruiseControlSpeed() or 0
    local baseDisplay = self:toDisplayUnit(baseSpeedKmh)
    local newDisplay = math.floor((baseDisplay + direction * self.STEP) * 10 + 0.5) / 10
    local newSpeedKmh = self:fromDisplayUnit(newDisplay)
    self:applyNewSpeed(vehicle, baseSpeedKmh, newSpeedKmh)
end

function CruiseControlFineTune:onSpeedUp(actionName, inputValue, callbackState, isAnalog)
    if CruiseControlFineTune.DEBUG then print("[CruiseControlFineTune] Taste 'erhöhen' ausgelöst.") end
    CruiseControlFineTune:adjustSpeedByDisplayStep(1)
end

function CruiseControlFineTune:onSpeedDown(actionName, inputValue, callbackState, isAnalog)
    if CruiseControlFineTune.DEBUG then print("[CruiseControlFineTune] Taste 'verringern' ausgelöst.") end
    CruiseControlFineTune:adjustSpeedByDisplayStep(-1)
end

addModEventListener(CruiseControlFineTune)

-- ============================================================================
-- Regelmäßiger Registrierungs-Refresh (Fahrzeugwechsel + Zeitintervall)
-- ============================================================================
-- Erzwingt eine frische Neuregistrierung der beiden Aktionen: sofort bei
-- jedem erkannten Fahrzeugwechsel, und zusätzlich alle paar Sekunden als
-- generelles Sicherheitsnetz - unabhängig von der konkreten Tastenbelegung
-- (kein SHIFT-Sonderfall mehr). Löst selbst NIE eine Geschwindigkeitsänderung
-- aus, das bleibt ausschließlich den beiden echten, umbelegbaren Aktionen
-- vorbehalten.
CruiseControlFineTune.REFRESH_INTERVAL = 3000 -- ms
CruiseControlFineTune._lastVehicle = nil
CruiseControlFineTune._lastRefreshTime = 0

function CruiseControlFineTune.refreshActionsPeriodically(vehicle)
    if vehicle == nil or vehicle.spec_drivable == nil then
        CruiseControlFineTune._lastVehicle = vehicle
        return
    end

    local now = (g_currentMission ~= nil and g_currentMission.time) or 0
    local vehicleChanged = vehicle ~= CruiseControlFineTune._lastVehicle
    local intervalElapsed = (now - CruiseControlFineTune._lastRefreshTime) >= CruiseControlFineTune.REFRESH_INTERVAL

    if vehicleChanged or intervalElapsed then
        CruiseControlFineTune.onVehicleRegisterActionEvents(vehicle)
        CruiseControlFineTune._lastRefreshTime = now
    end

    CruiseControlFineTune._lastVehicle = vehicle
end

-- ============================================================================
-- HUD-Dezimalanzeige
-- ============================================================================
CruiseControlFineTune.HUD_X_1DIGIT = 0.8815
CruiseControlFineTune.HUD_X_2DIGIT = 0.8865
CruiseControlFineTune.HUD_X_3DIGIT = 0.8915
CruiseControlFineTune.HUD_Y = 0.048027
CruiseControlFineTune.HUD_TEXT_SIZE = 0.01623

function CruiseControlFineTune.drawCruiseSpeedOverlay(speedMeter)
    local vehicle = CruiseControlFineTune:getCurrentlyControlledVehicle()
    CruiseControlFineTune.refreshActionsPeriodically(vehicle)
    CruiseControlFineTune.drawCruiseSpeedOverlaySafe(speedMeter)
end

function CruiseControlFineTune.drawCruiseSpeedOverlaySafe(speedMeter)
    if speedMeter == nil or speedMeter.vehicle == nil then
        return
    end
    local vehicle = speedMeter.vehicle
    if vehicle.getCruiseControlDisplayInfo == nil then
        return
    end

    local speed, isActive = vehicle:getCruiseControlDisplayInfo()
    if speed == nil then
        return
    end

    -- Interne Geschwindigkeit ist IMMER km/h - für die Anzeige (Nachkommastelle
    -- + Ziffernanzahl-Position) in die eingestellte Einheit umrechnen, exakt
    -- wie beim Setzen der Geschwindigkeit (CruiseControlFineTune:toDisplayUnit).
    local displaySpeed = CruiseControlFineTune:toDisplayUnit(speed)

    -- Nur Punkt + Nachkommastelle (native Zahl liefert das Spiel selbst)
    local roundedTenth = math.floor(displaySpeed * 10 + 0.5)
    local decimalDigit = roundedTenth % 10
    local integerPart = math.floor(roundedTenth / 10)
    local text = string.format(".%d", decimalDigit)

    -- Passende X-Position je nach Ziffernanzahl der ganzen Zahl wählen.
    local x
    if integerPart >= 100 then
        x = CruiseControlFineTune.HUD_X_3DIGIT
    elseif integerPart >= 10 then
        x = CruiseControlFineTune.HUD_X_2DIGIT
    else
        x = CruiseControlFineTune.HUD_X_1DIGIT
    end
    local y = CruiseControlFineTune.HUD_Y
    local size = CruiseControlFineTune.HUD_TEXT_SIZE

    local r, g, b, a = 1, 1, 1, 1
    if isActive and HUD ~= nil and HUD.COLOR ~= nil and HUD.COLOR.ACTIVE ~= nil then
        r, g, b, a = unpack(HUD.COLOR.ACTIVE)
    end

    setTextColor(r, g, b, a)
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(x, y, size, text)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end

if SpeedMeterDisplay ~= nil and SpeedMeterDisplay.draw ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    SpeedMeterDisplay.draw = Utils.appendedFunction(SpeedMeterDisplay.draw, CruiseControlFineTune.drawCruiseSpeedOverlay)
    print("[CruiseControlFineTune] HUD-Dezimalanzeige an SpeedMeterDisplay:draw angehängt.")
else
    print("[CruiseControlFineTune] FEHLER: SpeedMeterDisplay.draw oder Utils.appendedFunction nicht gefunden.")
end

-- ============================================================================
-- Konsolenbefehle (nur zum Testen/Debuggen)
-- ============================================================================
function CruiseControlFineTune:consoleTestAdjust(delta)
    self:adjustSpeed(tonumber(delta) or 0.1)
end

addConsoleCommand(
    "ccftCruiseAdjust",
    "Testet die Tempomat-Anpassung direkt, ohne Taste. Nutzung: ccftCruiseAdjust <delta, z.B. 0.1 oder -0.1>",
    "consoleTestAdjust",
    CruiseControlFineTune
)

function CruiseControlFineTune:consoleDebug()
    print("========== CruiseControlFineTune Debug ==========")
    print(string.format("An Drivable:onRegisterActionEvents angehängt: %s",
        tostring(Drivable ~= nil and Drivable.onRegisterActionEvents ~= nil)))
    print(string.format("InputAction.CCFT_INC vorhanden: %s", tostring(InputAction ~= nil and InputAction.CCFT_INC ~= nil)))
    print(string.format("InputAction.CCFT_DEC vorhanden: %s", tostring(InputAction ~= nil and InputAction.CCFT_DEC ~= nil)))

    local vehicle = self:getCurrentlyControlledVehicle()
    if vehicle == nil then
        print("Kein Fahrzeug aktuell gesteuert.")
        print("===================================================")
        return
    end

    if vehicle.ccftActionEvents ~= nil then
        local count = 0
        for _ in pairs(vehicle.ccftActionEvents) do
            count = count + 1
        end
        print(string.format("Fahrzeug-eigene ccftActionEvents registriert: %d", count))
    else
        print("Fahrzeug hat noch keine ccftActionEvents (onRegisterActionEvents evtl. noch nicht gelaufen).")
    end

    print(string.format("Fahrzeug: %s", tostring(vehicle.configFileName)))
    if vehicle.getCruiseControlSpeed ~= nil then
        print(string.format("Aktuell eingestellte Tempomat-Geschwindigkeit: %s", tostring(vehicle:getCruiseControlSpeed())))
    end
    if vehicle.getCruiseControlDisplayInfo ~= nil then
        local speed, isActive = vehicle:getCruiseControlDisplayInfo()
        print(string.format("HUD-Anzeigewert: Geschwindigkeit=%s aktiv=%s", tostring(speed), tostring(isActive)))
    end
    print("===================================================")
end

addConsoleCommand(
    "ccftDebug",
    "Zeigt Debug-Infos zu Tastenregistrierung, Fahrzeug und Tempomat-Status an.",
    "consoleDebug",
    CruiseControlFineTune
)

function CruiseControlFineTune:consoleDebugToggle()
    self.DEBUG = not self.DEBUG
    print(string.format("[CruiseControlFineTune] Laufende Debug-Ausgaben (Tastendruck/Geschwindigkeitsänderung): %s", tostring(self.DEBUG)))
end

addConsoleCommand(
    "ccftDebugToggle",
    "Schaltet laufende Debug-Ausgaben (Tastendruck/Geschwindigkeitsänderung) an/aus. Standard: aus.",
    "consoleDebugToggle",
    CruiseControlFineTune
)
