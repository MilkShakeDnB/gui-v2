/*
** Copyright (C) 2023 Victron Energy B.V.
** See LICENSE.txt for license information.
*/

import QtQuick
import Victron.VenusOS

AbstractListItem {
	id: root

	required property Device device
	required property bool animationEnabled
	required property Gradient temperatureGaugeGradient
	required property Gradient humidityGaugeGradient

	// Our Tuya bridge reserves temperature device instances 240..243.
	// Match the D-Bus service name where possible, but also accept those
	// instances: the GUI backend may prefix/suffix its service UID.
	readonly property bool isTuyaSensor: {
		if (!root.device || root.device.serviceType !== "temperature")
			return false
		const uid = String(root.device.serviceUid ?? "").toLowerCase()
		const matchingService = /(?:^|\/)com\.victronenergy\.temperature\.tuya_[a-z0-9_]+(?=\/|$)/.test(uid)
		const instance = Number(root.device.deviceInstance)
		const matchingInstance = Number.isInteger(instance) && instance >= 240 && instance <= 243
		return matchingService || matchingInstance
	}

	readonly property bool temperatureAvailable:
		temperatureItem.valid
		&& typeof temperatureItem.value === "number"
		&& isFinite(temperatureItem.value)
		&& (!root.isTuyaSensor
			|| (temperatureStatusItem.valid && temperatureStatusItem.value === "FRESH"))

	readonly property bool humidityAvailable:
		humidityItem.valid
		&& typeof humidityItem.value === "number"
		&& isFinite(humidityItem.value)
		&& (!root.isTuyaSensor
			|| (humidityStatusItem.valid && humidityStatusItem.value === "FRESH"))

	readonly property bool hasTwoGauges: temperatureAvailable && humidityAvailable

	readonly property string batteryStatus:
		batteryStateItem.valid && batteryStateItem.value !== null
			? String(batteryStateItem.value).toUpperCase() : "UNKNOWN"
	readonly property string temperatureStatus:
		temperatureStatusItem.valid && temperatureStatusItem.value !== null
			? String(temperatureStatusItem.value).toUpperCase() : "UNKNOWN"
	readonly property string humidityStatus:
		humidityStatusItem.valid && humidityStatusItem.value !== null
			? String(humidityStatusItem.value).toUpperCase() : "UNKNOWN"
	readonly property bool hasTuyaWarning: root.batteryStatus === "LOW"
		|| root.temperatureStatus !== "FRESH" || root.humidityStatus !== "FRESH"

	implicitWidth: Math.max(
		implicitBackgroundWidth + leftInset + rightInset,
		implicitContentWidth + leftPadding + rightPadding)
	implicitHeight: Math.max(
		implicitBackgroundHeight + topInset + bottomInset,
		implicitContentHeight + topPadding + bottomPadding)

	leftInset: Theme.geometry_levelsPage_panel_horizontalInset
	rightInset: Theme.geometry_levelsPage_panel_horizontalInset
	leftPadding: leftInset + Theme.geometry_levelsGauge_horizontalPadding
	rightPadding: rightInset + Theme.geometry_levelsGauge_horizontalPadding
	topPadding: Theme.geometry_levelsPage_panel_header_height + Theme.geometry_environmentGaugePanel_verticalPadding
	bottomPadding: Theme.geometry_environmentGaugePanel_verticalPadding
		+ (root.isTuyaSensor ? tuyaStatusFooter.implicitHeight + 12 : 0)

	background: Item {
		implicitWidth: Theme.geometry_levelsPage_panel_background_width
		implicitHeight: Theme.geometry_levelsPage_panel_background_height

		// The colour indicator is on the top in landscape, and not visible in portrait.
		Rectangle {
			id: colorIndicator

			width: parent.width
			height: Theme.geometry_levelsPage_panel_header_height
			topLeftRadius: Theme.geometry_levelsPage_panel_radius
			topRightRadius: Theme.geometry_levelsPage_panel_radius
			color: Theme.color_environmentGaugePanel_header
			visible: Theme.screenSize !== Theme.Portrait

			Label {
				anchors {
					left: parent.left
					right: parent.right
					bottom: parent.bottom
					margins: Theme.geometry_levelsPage_panel_background_title_padding
				}
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				text: Global.environmentInputs.sensorDisplayName(root.device)
			}
		}

		// Fill out the rest of the background with a background colour.
		Rectangle {
			anchors {
				fill: parent
				topMargin: Theme.geometry_levelsPage_panel_header_height
			}
			border.color: Theme.screenSize === Theme.Portrait ? "transparent" : Theme.color_environmentGaugePanel_header
			color: Theme.color_environmentGaugePanel_background
			topLeftRadius: colorIndicator.visible ? 0 : Theme.geometry_levelsPage_panel_radius
			topRightRadius: colorIndicator.visible ? 0 : Theme.geometry_levelsPage_panel_radius
			bottomLeftRadius: Theme.geometry_levelsPage_panel_radius
			bottomRightRadius: Theme.geometry_levelsPage_panel_radius
		}

		// Footer is placed on the background, below the padded gauge content.
		// Allow up to three wrapped lines on narrow landscape panels.
		Label {
			id: tuyaStatusFooter
			visible: root.isTuyaSensor
			anchors {
				left: parent.left
				right: parent.right
				bottom: parent.bottom
				leftMargin: root.leftPadding
				rightMargin: root.rightPadding
				bottomMargin: 6
			}
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.Wrap
			maximumLineCount: 3
			elide: Text.ElideRight
			font.pixelSize: Math.max(11, Math.round(Theme.font_size_body2 * 0.75))
			color: root.hasTuyaWarning ? Theme.color_orange : Theme.color_font_secondary
			text: "BAT " + root.batteryStatus
				+ "  |  T " + root.temperatureStatus
				+ "  |  H " + root.humidityStatus
		}
	}

	contentItem: Item {
		implicitWidth: gaugeFlow.implicitWidth
		// In landscape, stretch the height to fill the parent.
		// In portrait, size the height to the gauge content.
		implicitHeight: Theme.screenSize !== Theme.Portrait ? 0
				: (nameLabel.text.length ? nameLabel.height : 0) + gaugeFlow.height

		// In portrait, if there are two gauges, show the name here instead of within the outline.
		Label {
			id: nameLabel

			anchors {
				left: parent.left
				leftMargin: Theme.geometry_icon_size_medium + Theme.geometry_levelsGauge_horizontalSpacing
				right: parent.right
			}
			font.pixelSize: Theme.font_levelsGauge_title
			wrapMode: Text.Wrap
			text: Theme.screenSize === Theme.Portrait && root.hasTwoGauges ? Global.environmentInputs.sensorDisplayName(root.device) : ""
			color: Theme.color_font_primary
		}

		Flow {
			id: gaugeFlow

			readonly property int gaugeWidth: Theme.screenSize === Theme.Portrait ? parent.width
					: hasTwoGauges ? (parent.width - (2 * Theme.geometry_levelsPage_panel_border_width)) / 2
					: Theme.geometry_environmentGauge_width

			anchors {
				horizontalCenter: parent.horizontalCenter
				top: nameLabel.text.length ? nameLabel.bottom : undefined
			}
			width: Theme.screenSize === Theme.Portrait ? parent.width
					: root.hasTwoGauges ? gaugeWidth * 2
					: gaugeWidth
			flow: Theme.screenSize === Theme.Portrait ? Flow.TopToBottom : Flow.LeftToRight
			spacing: Theme.screenSize === Theme.Portrait ? Theme.geometry_levelsGauge_verticalPadding : 0

			LevelsGaugeOutline {
				width: gaugeFlow.gaugeWidth
				height: Theme.screenSize === Theme.Portrait ? implicitHeight : gaugeFlow.parent.height
				// If only humidity is fresh, do not show a misleading empty temperature gauge.
				visible: root.temperatureAvailable || !root.humidityAvailable
				name: root.hasTwoGauges ? "" : (Global.environmentInputs.sensorDisplayName(root.device))
				iconSource: "qrc:/images/icon_temp_32.svg"
				value: root.temperatureAvailable
					? (root.isTuyaSensor ? Math.round(temperatureItem.value * 10) / 10
						: Math.round(temperatureItem.value)) : NaN
				quantityDecimals: root.isTuyaSensor ? 1 : 0
				unit: Global.systemSettings.temperatureUnit
				unitText: Units.defaultUnitString(Global.systemSettings.temperatureUnit)
				quantityFormatHints: Theme.screenSize === Theme.Portrait ? 0 : Units.CompactUnitFormat
				gaugeHorizontalPadding: Theme.geometry_environmentGauge_gauge_horizontalPadding

				gauge: EnvironmentGauge {
					orientation: Theme.screenSize === Theme.Portrait ? Qt.Horizontal : Qt.Vertical
					value: root.temperatureAvailable ? temperatureItem.value : NaN
					minimumValue: Global.environmentInputs.temperatureGaugeMinimum(temperatureType.value)
					maximumValue: Global.environmentInputs.temperatureGaugeMaximum(temperatureType.value)
					stepSize: Global.environmentInputs.temperatureGaugeStepSize(temperatureType.value)
					highlightedValue: Theme.geometry_levelsPage_environment_temperatureGauge_highlightedValue
					minimumValueColor: Theme.color_blue
					maximumValueColor: Theme.color_red
					highlightedValueColor: Theme.color_levelsPage_environment_temperatureGauge_highlightValue
					gradient: root.temperatureGaugeGradient
					animationEnabled: root.animationEnabled
				}
			}

			LevelsGaugeOutline {
				width: gaugeFlow.gaugeWidth
				height: Theme.screenSize === Theme.Portrait ? implicitHeight : gaugeFlow.parent.height
				visible: root.humidityAvailable
				name: root.hasTwoGauges ? "" : (Global.environmentInputs.sensorDisplayName(root.device))
				iconSource: "qrc:/images/icon_humidity_32.svg"
				value: root.humidityAvailable ? Math.round(humidityItem.value) : NaN
				unit: VenusOS.Units_Percentage
				// Don't translate. Short local acronyms often don't exist. RH is an international standard.
				// In case user is not familiar with the acronym "RH" there is also drop icon and percentage sign (%).
				unitText: "RH"
				quantityFormatHints: Theme.screenSize === Theme.Portrait ? 0 : Units.CompactUnitFormat
				gaugeHorizontalPadding: Theme.geometry_environmentGauge_gauge_horizontalPadding
				gauge: root.humidityAvailable ? humidityGaugeComponent : null

				Component {
					id: humidityGaugeComponent

					EnvironmentGauge {
						orientation: Theme.screenSize === Theme.Portrait ? Qt.Horizontal : Qt.Vertical
						value: root.humidityAvailable ? humidityItem.value : NaN
						minimumValue: Theme.geometry_levelsPage_environment_humidityGauge_minimumValue
						maximumValue: Theme.geometry_levelsPage_environment_humidityGauge_maximumValue
						stepSize: Theme.geometry_environmentGauge_tick_step
						highlightedValue: Theme.geometry_levelsPage_environment_humidityGauge_highlightedValue
						minimumValueColor: Theme.color_orange
						maximumValueColor: Theme.color_blue
						highlightedValueColor: Theme.color_green
						gradient: root.humidityGaugeGradient
						animationEnabled: root.animationEnabled
					}
				}
			}
		}

		VeQuickItem {
			id: temperatureType
			readonly property int intValue: valid ? value : VenusOS.Temperature_DeviceType_Generic
			uid: root.device ? root.device.serviceUid + "/TemperatureType" : ""
		}
	}

	VeQuickItem {
		id: batteryStateItem
		uid: root.isTuyaSensor && root.device ? root.device.serviceUid + "/Tuya/BatteryState" : ""
	}

	VeQuickItem {
		id: temperatureStatusItem
		uid: root.isTuyaSensor && root.device ? root.device.serviceUid + "/Tuya/TemperatureStatus" : ""
	}

	VeQuickItem {
		id: humidityStatusItem
		uid: root.isTuyaSensor && root.device ? root.device.serviceUid + "/Tuya/HumidityStatus" : ""
	}

	VeQuickItem {
		id: temperatureAgeItem
		uid: root.isTuyaSensor && root.device ? root.device.serviceUid + "/Tuya/TemperatureAgeMinutes" : ""
	}

	VeQuickItem {
		id: humidityAgeItem
		uid: root.isTuyaSensor && root.device ? root.device.serviceUid + "/Tuya/HumidityAgeMinutes" : ""
	}

	VeQuickItem {
		id: humidityItem
		uid: root.device ? root.device.serviceUid + "/Humidity" : ""
	}

	VeQuickItem {
		id: temperatureItem
		uid: root.device ? root.device.serviceUid + "/Temperature" : ""
		sourceUnit: Units.unitToVeUnit(VenusOS.Units_Temperature_Celsius)
		displayUnit: Units.unitToVeUnit(Global.systemSettings.temperatureUnit)
	}
}
