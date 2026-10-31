import QtQuick
import QtQml.Models
import Victron.VenusOS
import Victron.Boat as Boat

ObjectModel {
	id: root

	required property SwipeView view
	readonly property list<SwipeViewPage> pages
		: showBoatPage && showLevelsPage ? [ boatPageLoader.item, briefPage, overviewPage, levelsPageLoader.item, heatingPage, notificationsPage, settingsPage ]
		: showBoatPage ? [ boatPageLoader.item, briefPage, overviewPage, heatingPage, notificationsPage, settingsPage ]
		: showLevelsPage ? [ briefPage, overviewPage, levelsPageLoader.item, heatingPage, notificationsPage, settingsPage ]
		: [ briefPage, overviewPage, heatingPage, notificationsPage, settingsPage ]
	readonly property bool showLevelsPage: levelsPageLoader.active && !!levelsPageLoader.item
	readonly property bool showBoatPage: boatPageLoader.active && !!boatPageLoader.item
	readonly property int tankCount: Global.tanks ? Global.tanks.totalTankCount : 0
	readonly property int environmentInputCount: Global.environmentInputs ? Global.environmentInputs.model.count : 0

	readonly property bool completed: _completed
		&& Global.dataManagerLoaded
		&& Global.systemSettings
		&& Global.tanks
		&& Global.environmentInputs
		&& ((boatPageLoader.active && levelsPageLoader.active) ? pages.length === 7
		  : boatPageLoader.active ? pages.length === 6
		  : levelsPageLoader.active ? pages.length === 6
		  : pages.length === 5)

	property bool _completed: false

	Loader {
		id: boatPageLoader

		active: showBoatPageItem.value ?? false
		sourceComponent: Boat.BoatPage {
			view: root.view
		}

		VeQuickItem {
			id: showBoatPageItem
			uid: !!Global.systemSettings ? Global.systemSettings.serviceUid + "/Settings/Gui/ElectricPropulsionUI/Enabled" : ""
		}
	}

	BriefPage {
		id: briefPage
		view: root.view

		Image {
			width: status === Image.Null ? 0 : Theme.geometry_screen_width
			fillMode: Image.PreserveAspectFit
			source: UiConfig.demoImageFileName
			onStatusChanged: {
				if (status === Image.Ready) {
					console.info("Loaded demo image:", source)
				}
			}
		}
	}

	OverviewPage {
		id: overviewPage
		view: root.view
	}

	Loader {
		id: levelsPageLoader

		active: root.tankCount > 0 || root.environmentInputCount > 0
		sourceComponent: LevelsPage {
			view: root.view
		}
	}

	HeatingPage {
		id: heatingPage
		view: root.view
	}

	NotificationsPage {
		id: notificationsPage
		view: root.view
	}

	SettingsPage {
		id: settingsPage
		view: root.view
	}

	// V7 PHASE 2: Monitoring plus a CONTROL-LOCKED user interface.
	// No write endpoints, Bluetooth commands, or heater control are present.
	component HeatingPage : SwipeViewPage {
		id: heatingRoot

		title: "Heating"
		iconSource: "qrc:/images/icon_temp_32.svg"
		url: "qrc:/qt/qml/Victron/VenusOS/pages/HeatingPage.qml"
		topLeftButton: VenusOS.StatusBar_LeftButton_ControlsInactive
		fullScreenWhenIdle: true
		focusPolicy: Qt.TabFocus

		// Read-only JSON published separately from the existing BLE reader.
		readonly property string statusUrl: "https://192.168.10.215/sunster-v7-k51/status"
		readonly property int maxReadingAgeMs: 720000
		// Stage8: closed unless AUTHENTICATED and short-lived gate is confirmed.
		property var heaters: ({})
		property var recentDirectReadbacks: ({})
		property string fetchState: "Waiting for Sunster data"
		property double nowMs: Date.now()
		property bool requestPending: false

		// V7 gated local bridge. NO credentials are bundled in the WASM build.
		readonly property string apiBase: "/sunster-v7-k51/"
		property var allowedActions: ({})
		property bool gateOpen: false
		property bool authenticated: false
		property bool controlBusy: false
		property string csrf: ""
		property var proposed: null
		property string controlMessage: "Control locked. Monitoring remains available."
		readonly property bool guiControlEnabled: false // Stage 4: monitor + build validation only
		readonly property bool canControl: guiControlEnabled && gateOpen && authenticated && !controlBusy

		function supports(heater, action) {
			const actions = allowedActions[heater]
			return canControl && readingIsFresh(heaters[heater]) && Array.isArray(actions) && actions.indexOf(action) >= 0
		}

		function requestApi(method, path, body, callback, withCsrf) {
			if (Qt.platform.os !== "wasm") return
			const req = new XMLHttpRequest()
			req.open(method, apiBase + path)
			req.timeout = 120000
			if (method === "POST") {
				req.setRequestHeader("Content-Type", "application/json")
				if (withCsrf) req.setRequestHeader("X-Sunster-CSRF", csrf)
			}
			let callbackFinished = false
			function finishOnce(code, data) {
				if (callbackFinished) return
				callbackFinished = true
				callback(code, data)
			}
			req.onreadystatechange = function() {
				if (req.readyState !== 4) return
				let result = ({})
				try { result = JSON.parse(req.responseText) } catch (e) {}
				finishOnce(req.status, result)
			}
			req.onerror = function() { finishOnce(0, ({error: "Network unavailable"})) }
			req.ontimeout = function() { finishOnce(0, ({error: "API timeout"})) }
			req.onabort = function() { finishOnce(0, ({error: "Request aborted"})) }
			req.send(method === "POST" ? JSON.stringify(body) : null)
		}

		function checkGateway() {
			requestApi("GET", "health", null, function(code, data) {
				if (code !== 200 || data.schema_version !== 1) {
					gateOpen = false
					authenticated = false
					csrf = ""
					allowedActions = ({})
					proposed = null
					controlMessage = "Gateway unavailable; preview only"
					return
				}
				allowedActions = data.actions || ({})
				gateOpen = data.gate_active === true
				if (!gateOpen || data.authenticated !== true) {
					authenticated = false
					csrf = ""
					proposed = null
				}
			}, false)
		}

		function unlock(pin) {
			if (controlBusy || !gateOpen) return
			controlBusy = true
			requestApi("POST", "unlock", ({pin: pin}), function(code, data) {
				controlBusy = false
				if (code === 200 && data.authenticated === true && typeof data.csrf === "string") {
					authenticated = true
					csrf = data.csrf
					controlMessage = "Unlocked for supervised control"
				} else {
					controlMessage = "Unlock blocked (" + code + ")"
				}
			}, false)
		}

		function propose(heater, action, value, expected) {
			if (!supports(heater, action)) return
			proposed = ({heater: heater, action: action, value: value, expected: expected})
			controlMessage = "Confirm: " + heater + " / " + action + " -> " + String(value)
		}

		function confirmProposed() {
			if (!proposed || controlBusy || !supports(proposed.heater, proposed.action)) return
			const requested = proposed
			proposed = null
			controlBusy = true
			requestApi("POST", "command", requested, function(code, result) {
				controlBusy = false
				if (code === 200 && result.confirmed === true) {
					controlMessage = "Readback confirmed for " + requested.heater
					// Passive BLE reader remains the only source of observed state.
				} else {
					controlMessage = "NOT CONFIRMED (" + code + "). Check the heater/app before retrying."
				}
				checkGateway()
			}, true)
		}

		function timestampMs(raw) {
			if (typeof raw === "number" && isFinite(raw))
				return raw > 100000000000 ? raw : raw * 1000
			if (typeof raw === "string" && raw.length > 0) {
				const numberValue = Number(raw)
				if (isFinite(numberValue) && raw.trim() !== "")
					return numberValue > 100000000000 ? numberValue : numberValue * 1000
				const parsed = Date.parse(raw)
				return isFinite(parsed) ? parsed : 0
			}
			return 0
		}

		function readingIsFresh(reading) {
			// Fresh timestamps alone do not mean that the last BLE read succeeded.
			if (!reading || !reading.observed_at || String(reading.status).toLowerCase() !== "ok") return false
			const ageMs = nowMs - timestampMs(reading.observed_at)
			return ageMs >= -30000 && ageMs <= maxReadingAgeMs
		}

		function numericTemperature(value) {
			// Numeric validation is for display only, not for safe control decisions.
			return typeof value === "number" && isFinite(value)
					&& value >= -60 && value <= 150
		}

		function degrees(value) {
			return numericTemperature(value) ? value.toFixed(1) + " °C" : "—"
		}

		// Phase 6: display only the field valid for the observed heater mode.
		// Never turn a power level or a stale reading into a thermostat setpoint.
		function settingLabel(reading) {
			if (!readingIsFresh(reading)) return "Setting"
			if (reading.mode === "level") return "Power level"
			if (reading.mode === "thermostat") return "Setpoint"
			return "Setting"
		}

		function settingValue(reading) {
			if (!readingIsFresh(reading)) return "—"
			if (reading.mode === "level") {
				const level = reading.power_level
				return typeof level === "number" && isFinite(level)
					&& Math.floor(level) === level && level >= 1 && level <= 10
					? String(level) + " / 10" : "—"
			}
			if (reading.mode === "thermostat") {
				const setpoint = reading.setpoint_c
				return typeof setpoint === "number" && isFinite(setpoint)
					&& setpoint >= 0 && setpoint <= 60
					? degrees(setpoint) : "—"
			}
			return "—"
		}

		function readState(reading) {
			if (!reading) return "NO DATA"
			if (String(reading.status).toLowerCase() !== "ok") return "BLE OFFLINE / UNAVAILABLE"
			return readingIsFresh(reading) ? "RECENT READING" : "STALE BLE READING"
		}

		function refresh() {
			if (requestPending) return
			if (Qt.platform.os !== "wasm") {
				fetchState = "Status JSON is available in the Cerbo web interface (WASM)"
				return
			}
			requestPending = true
			const req = new XMLHttpRequest()
			req.onreadystatechange = function() {
				if (req.readyState !== 4) return
				requestPending = false
				if (req.status !== 200) {
					fetchState = "Sunster data source unavailable (HTTP " + req.status + ")"
					return
				}
				try {
					const data = JSON.parse(req.responseText)
					if (!data || data.schema_version !== 1 || !data.heaters ||
						typeof data.heaters !== "object")
						throw new Error("Unsupported Sunster data format")
					const a = data.heaters["Caravan Heater"]
					const b = data.heaters["Caravan Bedroom"]
					if (!a || !b || typeof a !== "object" || typeof b !== "object")
						throw new Error("Missing one of the heaters")
					const merged = Object.assign(({}), data.heaters)
					for (const key of ["Caravan Heater", "Caravan Bedroom"]) {
						const direct = recentDirectReadbacks[key]
						const cached = merged[key]
						if (direct && readingIsFresh(direct) &&
							timestampMs(direct.observed_at) > timestampMs(cached.observed_at))
							merged[key] = direct
					}
					heaters = merged
					nowMs = Date.now()
					fetchState = "Reader response received"
				} catch (error) {
					fetchState = "Invalid Sunster data: " + error.message
				}
			}
			req.onerror = function() {
				requestPending = false
				fetchState = "Cannot reach Sunster status source"
			}
			req.open("GET", statusUrl + "?v=" + Date.now())
			req.timeout = 10000
			req.ontimeout = function() {
				requestPending = false
				fetchState = "Sunster data source timeout"
			}
			req.send()
		}

		Component.onCompleted: { refresh(); checkGateway() }

		onIsCurrentPageChanged: if (isCurrentPage) refresh()

		Timer {
			interval: 15000
			repeat: true
			running: true // V7 diagnostic: refresh independently of current page
			onTriggered: {
				heatingRoot.nowMs = Date.now()
				heatingRoot.refresh()
				heatingRoot.checkGateway()

			}
		}

		Flickable {
			anchors.fill: parent
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			contentHeight: contentColumn.implicitHeight + 40

			Column {
				id: contentColumn
				width: parent.width > 40 ? parent.width - 36 : parent.width
				x: Math.max(0, (parent.width - width) / 2)
				y: 16
				spacing: 12

				Text {
					width: parent.width
					text: "Sunster Heating"
					font.pixelSize: 22
					font.bold: true
					color: Theme.color_font_primary
				}
				Text {
					width: parent.width
					text: heatingRoot.fetchState
					font.pixelSize: 12
					color: Theme.color_font_secondary
					wrapMode: Text.Wrap
				}
				Rectangle {
					width: parent.width
					height: lockedBanner.implicitHeight + 24
					radius: 8
					color: Theme.color_listItem_background
					border.width: 1
					border.color: Theme.color_orange
					Text {
						id: lockedBanner
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						anchors.margins: 12
						text: heatingRoot.canControl ? "SUPERVISED CONTROL ACTIVE" : "CONTROL LOCKED - READ-ONLY UNTIL UNLOCKED"
						font.pixelSize: 12
						font.bold: true
						color: Theme.color_orange
						wrapMode: Text.Wrap
					}
				}

				Text {
					width: parent.width
					text: heatingRoot.controlMessage
					wrapMode: Text.Wrap
					font.pixelSize: 12
					color: Theme.color_font_secondary
				}
				Row {
					spacing: 10
					visible: heatingRoot.gateOpen && !heatingRoot.authenticated
					Rectangle {
						width: 130; height: 42; radius: 6
						color: Theme.color_listItem_background
						border.color: Theme.color_listItem_separator
						TextInput {
							id: controlPin
							anchors.fill: parent
							anchors.margins: 8
							font.pixelSize: 19
							color: Theme.color_font_primary
							echoMode: TextInput.Password
							inputMethodHints: Qt.ImhDigitsOnly
							maximumLength: 8
						}
					}
					Rectangle {
						width: 118; height: 42; radius: 8
						color: Theme.color_listItem_background
						border.color: Theme.color_ok
						Text { anchors.centerIn: parent; text: "UNLOCK"; color: Theme.color_font_primary }
						MouseArea { anchors.fill: parent; onClicked: { heatingRoot.unlock(controlPin.text); controlPin.text = "" } }
					}
				}
				Rectangle {
					width: parent.width
					height: 62
					radius: 8
					visible: heatingRoot.proposed !== null
					color: Theme.color_listItem_background
					border.color: Theme.color_orange
					Row {
						anchors.centerIn: parent; spacing: 14
						Text {
							text: "Confirm " + (heatingRoot.proposed ? heatingRoot.proposed.action : "")
							font.pixelSize: 14; color: Theme.color_font_primary
						}
						Rectangle {
							width: 122; height: 42; radius: 6
							color: Theme.color_listItem_background
							border.color: Theme.color_ok
							Text { anchors.centerIn: parent; text: "CONFIRM"; color: Theme.color_font_primary }
							MouseArea { anchors.fill: parent; onClicked: heatingRoot.confirmProposed() }
						}
						Rectangle {
							width: 76; height: 42; radius: 6
							color: Theme.color_listItem_background
							Text { anchors.centerIn: parent; text: "CANCEL"; color: Theme.color_font_primary }
							MouseArea { anchors.fill: parent; onClicked: heatingRoot.proposed = null }
						}
					}
				}

				Grid {
					id: heaterGrid
					width: parent.width
					columns: Theme.screenSize === Theme.Portrait ? 1 : 2
					spacing: 12

					Repeater {
						model: ["Caravan Heater", "Caravan Bedroom"]
						delegate: Rectangle {
							id: heaterCard
							required property string modelData
							readonly property var reading: heatingRoot.heaters[modelData] || null
							readonly property bool fresh: heatingRoot.readingIsFresh(reading)
							width: (heaterGrid.width - heaterGrid.spacing * (heaterGrid.columns - 1)) / heaterGrid.columns
							height: cardContent.implicitHeight + 28
							radius: 12
							color: Theme.color_listItem_background
							border.width: 1
							border.color: Theme.color_listItem_separator

							Column {
								id: cardContent
								x: 14
								y: 14
								width: parent.width - 28
								spacing: 12

								Text {
									width: parent.width
									text: heaterCard.modelData === "Caravan Heater" ? "Heater Living Room" :
									heaterCard.modelData === "Caravan Bedroom" ? "Heater Bedroom" :
									heaterCard.modelData
									font.pixelSize: 19
									font.bold: true
									color: Theme.color_font_primary
								}
								Text {
									width: parent.width
									text: heatingRoot.readState(heaterCard.reading)
									font.pixelSize: 12
									font.bold: true
									color: heaterCard.fresh ? Theme.color_ok : Theme.color_orange
									elide: Text.ElideRight
								}
								Row {
									spacing: 22
									Column {
										spacing: 3
										Column {
										spacing: 3
										Text {
											text: "Current Temperature"
											font.pixelSize: 11
											color: Theme.color_font_secondary
										}
										Text {
											text: heaterCard.fresh && heaterCard.reading
												? heatingRoot.degrees(heaterCard.reading.temperature_c_candidate)
												: "—"
											font.pixelSize: 26
											font.bold: true
											color: Theme.color_font_primary
										}
									}
									Text { text: heatingRoot.settingLabel(heaterCard.reading); font.pixelSize: 11; color: Theme.color_font_secondary }
										Text {
											text: heatingRoot.settingValue(heaterCard.reading)
											font.pixelSize: 22
											font.bold: true
											color: Theme.color_font_primary
										}
									}
								}
								Text {
								    width: parent.width
								    text: heaterCard.fresh && heaterCard.reading
								        ? (heaterCard.reading.mode === "thermostat" ? "MODE: THERMOSTAT"
								            : heaterCard.reading.mode === "level" ? "MODE: LEVEL" : "MODE: UNKNOWN")
								        : "MODE: UNAVAILABLE"
								    font.pixelSize: 13
								    font.bold: true
								    color: Theme.color_font_primary
								}

								Text {
									width: parent.width
									text: !heaterCard.fresh || !heaterCard.reading
										? "AUTO: unavailable (not POWER)"
										: heaterCard.reading.automatic_heating_raw === 1
										? "AUTO: ON (independent of POWER)"
										: heaterCard.reading.automatic_heating_raw === 0
										? "AUTO: OFF (heater can still run at level 1)"
										: "AUTO: unknown (not POWER)"
									font.pixelSize: 12
									color: Theme.color_font_secondary
									wrapMode: Text.Wrap
								}
								Text {
									width: parent.width
									text: "Last BLE read: " + (heaterCard.reading && heaterCard.reading.observed_at
										? String(heaterCard.reading.observed_at) : "—")
									font.pixelSize: 11
									color: Theme.color_font_secondary
									elide: Text.ElideRight
								}
								Rectangle {
									width: parent.width
									height: 1
									color: Theme.color_listItem_separator
								}

                            // V7 HEATING INTERFACE: READ-ONLY PREVIEW

                            Text {
                                text: "POWER (disabled until ON/OFF verified on hardware)"
                                font.pixelSize: 12
                                color: Theme.color_font_secondary
                            }
                            Row {
                                spacing: 10
                                Repeater {
                                    model: ["POWER ON", "POWER OFF"]
                                    delegate: Rectangle {
                                        required property string modelData
                                        width: 112; height: 42; radius: 8
                                        color: Theme.color_listItem_background
                                        border.width: 1
                                        border.color: Theme.color_font_disabled
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData
                                            color: Theme.color_font_disabled
                                        }
                                    }
                                }
                            }

                            Text {
                                text: "MODE"
                                font.pixelSize: 12
                                color: Theme.color_font_secondary
                            }
                            Row {
                                spacing: 10
                                Repeater {
                                    model: ["THERMOSTAT", "LEVEL"]
                                    delegate: Rectangle {
                                        id: modePreview
                                        required property string modelData
                                        readonly property bool selected:
                                            heaterCard.fresh && heaterCard.reading &&
                                            heaterCard.reading.mode ===
                                            (modelData === "THERMOSTAT" ? "thermostat" : "level")
                                        width: 112; height: 42; radius: 8
                                        color: Theme.color_listItem_background
                                        border.width: selected ? 2 : 1
                                        border.color: selected ? Theme.color_ok : Theme.color_font_disabled
                                        Text {
                                            anchors.centerIn: parent
                                            text: modePreview.modelData
                                            font.pixelSize: 11
                                            color: modePreview.selected
                                                ? Theme.color_font_primary
                                                : Theme.color_font_disabled
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: heaterCard.fresh && heatingRoot.supports(heaterCard.modelData, "mode")
                                            onClicked: heatingRoot.propose(heaterCard.modelData, "mode",
                                                modePreview.modelData === "THERMOSTAT" ? "thermostat" : "level",
                                                heaterCard.reading.mode)
                                        }
                                    }
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: 10
                                visible: heaterCard.fresh && heaterCard.reading &&
                                         heaterCard.reading.mode === "thermostat"
                                Text {
                                    text: "THERMOSTAT AUTO"
                                    font.pixelSize: 12
                                    color: Theme.color_font_secondary
                                }
                                Row {
                                    spacing: 10
                                    Repeater {
                                        model: ["AUTO ON", "AUTO OFF"]
                                        delegate: Rectangle {
                                            id: autoPreview
                                            required property string modelData
                                            readonly property bool selected:
                                                heaterCard.fresh && heaterCard.reading &&
                                                typeof heaterCard.reading.automatic_heating_raw === "number" &&
                                                (heaterCard.reading.automatic_heating_raw ===
                                                    (modelData === "AUTO ON" ? 1 : 0))
                                            width: 112; height: 42; radius: 8
                                            color: Theme.color_listItem_background
                                            border.width: selected ? 2 : 1
                                            border.color: selected ? Theme.color_ok : Theme.color_font_disabled
                                            Text {
                                                anchors.centerIn: parent
                                                text: autoPreview.modelData
                                                color: autoPreview.selected
                                                    ? Theme.color_font_primary
                                                    : Theme.color_font_disabled
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                enabled: heaterCard.fresh && heatingRoot.supports(heaterCard.modelData, "auto")
                                                onClicked: heatingRoot.propose(heaterCard.modelData, "auto",
                                                    autoPreview.modelData === "AUTO ON",
                                                    heaterCard.reading.automatic_heating_raw === 1)
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                width: parent.width
                                text: heaterCard.fresh && heaterCard.reading
                                    ? (heaterCard.reading.mode === "thermostat"
                                        ? "TEMPERATURE SETPOINT"
                                        : heaterCard.reading.mode === "level"
                                        ? "HEATING LEVEL" : "SETTING UNAVAILABLE")
                                    : "SETTING UNAVAILABLE"
                                font.pixelSize: 12
                                color: Theme.color_font_secondary
                            }

                            Row {
                                spacing: 18
                                Repeater {
                                    model: ["−", "+"]
                                    delegate: Rectangle {
                                        required property string modelData
                                        width: 92; height: 44; radius: 8
                                        color: Theme.color_listItem_background
                                        border.width: 1
                                        border.color: Theme.color_font_disabled
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData
                                            font.pixelSize: 22
                                            color: Theme.color_font_disabled
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: heaterCard.fresh && heaterCard.reading &&
                                                heatingRoot.supports(heaterCard.modelData,
                                                    heaterCard.reading.mode === "thermostat" ? "setpoint" : "level")
                                            onClicked: {
                                                const thermostat = heaterCard.reading.mode === "thermostat"
                                                const existing = thermostat ? heaterCard.reading.setpoint_c : heaterCard.reading.power_level
                                                if (typeof existing !== "number" || !isFinite(existing)) return
                                                const plus = modelData === "+" ? 1 : -1
                                                heatingRoot.propose(heaterCard.modelData,
                                                    thermostat ? "setpoint" : "level", existing + plus, existing)
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                width: parent.width
                                text: heatingRoot.canControl ? "Select action, then press CONFIRM" : "Control locked; status display only"
                                font.pixelSize: 11
                                color: Theme.color_orange
                            }

							}
						}
					}
				}

			}
		}
	}

	Component.onCompleted: Qt.callLater(function() { root._completed = true })
}
