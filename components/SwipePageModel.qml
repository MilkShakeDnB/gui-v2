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
		readonly property string statusUrl: "https://192.168.10.215/sunster-v7/status.json"
		readonly property int maxReadingAgeMs: 720000
		readonly property bool controlsVerified: false // FAIL-CLOSED: never change without validated BLE protocol + authenticated server
		property var heaters: ({})
		property string fetchState: "Waiting for Sunster data"
		property double nowMs: Date.now()
		property bool requestPending: false

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
					heaters = data.heaters
					nowMs = Date.now()
					fetchState = "Reader response received — control remains locked"
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

		Component.onCompleted: refresh()

		onIsCurrentPageChanged: if (isCurrentPage) refresh()

		Timer {
			interval: 15000
			repeat: true
			running: true // V7 diagnostic: refresh independently of current page
			onTriggered: {
				heatingRoot.nowMs = Date.now()
				heatingRoot.refresh()
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
						text: "CONTROL LOCKED  •  Bluetooth commands have not been validated. Display only."
						font.pixelSize: 12
						font.bold: true
						color: Theme.color_orange
						wrapMode: Text.Wrap
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
									text: heaterCard.modelData
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
										Text { text: "Temperature*"; font.pixelSize: 11; color: Theme.color_font_secondary }
										Text {
											text: heaterCard.fresh && heaterCard.reading
												? heatingRoot.degrees(heaterCard.reading.temperature_c_candidate) : "—"
											font.pixelSize: 22
											font.bold: true
											color: Theme.color_font_primary
										}
									}
									Column {
										spacing: 3
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
								Text {
									text: "POWER  •  CONTROL PREVIEW"
									font.pixelSize: 11
									font.bold: true
									color: Theme.color_font_secondary
								}
								Row {
									spacing: 10
									Repeater {
										model: ["ON", "OFF"]
										delegate: Rectangle {
											required property string modelData
											width: 92
											height: 40
											radius: 8
											color: Theme.color_listItem_background
											border.color: Theme.color_font_disabled
											border.width: 1
											Text {
												anchors.centerIn: parent
												text: modelData
												font.bold: true
												color: Theme.color_font_disabled
											}
											// No MouseArea: incapable of sending BLE commands.
										}
									}
								}
								Text {
									text: "SETPOINT  •  CONTROL PREVIEW"
									font.pixelSize: 11
									font.bold: true
									color: Theme.color_font_secondary
								}
								Row {
									spacing: 18
									Repeater {
										model: ["−", "+"]
										delegate: Rectangle {
											required property string modelData
											width: 92
											height: 40
											radius: 8
											color: Theme.color_listItem_background
											border.color: Theme.color_font_disabled
											border.width: 1
											Text {
												anchors.centerIn: parent
												text: modelData
												font.pixelSize: 20
												color: Theme.color_font_disabled
											}
											// No MouseArea: control buttons deliberately inert.
										}
									}
								}
								Text {
									width: parent.width
									text: "Locked until command protocol and cooldown behavior are validated."
									font.pixelSize: 11
									color: Theme.color_font_secondary
									wrapMode: Text.Wrap
								}
							}
						}
					}
				}

				Text {
					width: parent.width
					text: "* Live temperature remains experimental until checked against the original Sunster app. No heater commands are sent."
					font.pixelSize: 12
					color: Theme.color_font_secondary
					wrapMode: Text.Wrap
				}
			}
		}
	}

	Component.onCompleted: Qt.callLater(function() { root._completed = true })
}
