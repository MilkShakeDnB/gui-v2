/*
** Copyright (C) 2023 Victron Energy B.V.
** See LICENSE.txt for license information.
*/

import QtQuick
import Victron.VenusOS

QtObject {
	id: root

	// The configuration lives on the GX (com.victronenergy.settings), not in
	// browser storage, so every device sees the same ordering and labels.
	// This path must be registered once on Venus OS using the included helper.
	readonly property VeQuickItem sensorLayoutItem: VeQuickItem {
		uid: Global.systemSettings?.serviceUid
			? Global.systemSettings.serviceUid + "/Settings/Custom/Tuya/GuiSensorLayout"
			: ""
	}

	readonly property bool sensorLayoutAvailable: sensorLayoutItem.valid
	readonly property var sensorLayout: {
		const empty = { order: [], hidden: [], names: {} }
		if (!sensorLayoutItem.valid || typeof sensorLayoutItem.value !== "string") return empty
		try {
			const parsed = JSON.parse(sensorLayoutItem.value)
			if (!parsed || typeof parsed !== "object") return empty
			return {
				order: Array.isArray(parsed.order) ? parsed.order : [],
				hidden: Array.isArray(parsed.hidden) ? parsed.hidden : [],
				names: parsed.names && typeof parsed.names === "object" && !Array.isArray(parsed.names)
					? parsed.names : {},
			}
		} catch (error) {
			console.warn("Invalid Tuya GUI sensor layout configuration:", error)
			return empty
		}
	}

	readonly property var orderedInstances: sensorLayout.order.map((v) => String(v))
	readonly property var hiddenInstances: sensorLayout.hidden.map((v) => String(v))

	// Unfiltered model powers settings, so hidden sensors remain manageable.
	readonly property FilteredDeviceModel allSensors: FilteredDeviceModel {
		serviceTypes: ["temperature"]
		sorting: FilteredDeviceModel.DeviceInstance
	}

	function sensorDisplayName(device) {
		if (!device) return ""
		const configured = sensorLayout.names[String(device.deviceInstance)]
		return typeof configured === "string" && configured.trim().length
			? configured.trim() : (device.name ?? "")
	}

	function sensorVisible(instance) {
		return hiddenInstances.indexOf(String(instance)) < 0
	}

	function _writeLayout(data) {
		if (!sensorLayoutItem.valid) return false
		sensorLayoutItem.setValue(JSON.stringify(data))
		return true
	}

	function setSensorName(instance, name) {
		const data = JSON.parse(JSON.stringify(sensorLayout))
		const key = String(instance)
		const trimmed = String(name).trim()
		if (trimmed) data.names[key] = trimmed
		else delete data.names[key]
		return _writeLayout(data)
	}

	function setSensorVisible(instance, show) {
		const data = JSON.parse(JSON.stringify(sensorLayout))
		const key = String(instance)
		data.hidden = data.hidden.map((v) => String(v)).filter((v) => v !== key)
		if (!show) data.hidden.push(key)
		return _writeLayout(data)
	}

	function moveSensor(instance, step) {
		if (!sensorLayoutItem.valid || (step !== 1 && step !== -1)) return false
		const data = JSON.parse(JSON.stringify(sensorLayout))
		const order = data.order.map((v) => String(v))
		// Add newly detected sensors to the tail, in predictable instance order.
		for (let i = 0; i < allSensors.count; ++i) {
			const device = allSensors.deviceAt(i)
			if (device && order.indexOf(String(device.deviceInstance)) < 0)
				order.push(String(device.deviceInstance))
		}
		const index = order.indexOf(String(instance))
		const target = index + step
		if (index < 0 || target < 0 || target >= order.length) return false
		const current = order[index]
		order[index] = order[target]
		order[target] = current
		data.order = order
		return _writeLayout(data)
	}

	readonly property FilteredDeviceModel model: FilteredDeviceModel {
		serviceTypes: ["temperature"]
		sorting: FilteredDeviceModel.DeviceInstance
		preferredDeviceInstances: root.orderedInstances
		hiddenDeviceInstances: root.hiddenInstances
	}

	readonly property ListModel _temperatureDetails: ListModel {
		ListElement {
			description: QT_TR_NOOP("Battery")
			temperatureGaugeMinimum: -20
			temperatureGaugeMaximum: 60
			temperatureGaugeStep: 10
		}
		ListElement {
			description: QT_TR_NOOP("Fridge")
			temperatureGaugeMinimum: 0
			temperatureGaugeMaximum: 20
			temperatureGaugeStep: 5
		}
		ListElement {
			description: QT_TR_NOOP("Generic")
			temperatureGaugeMinimum: -40
			temperatureGaugeMaximum: 60
			temperatureGaugeStep: 10
		}
		ListElement {
			description: QT_TR_NOOP("Room")
			temperatureGaugeMinimum: 5
			temperatureGaugeMaximum: 35
			temperatureGaugeStep: 10
		}
		ListElement {
			description: QT_TR_NOOP("Outdoor")
			temperatureGaugeMinimum: -40
			temperatureGaugeMaximum: 60
			temperatureGaugeStep: 10
		}
		ListElement {
			description: QT_TR_NOOP("Water Heater")
			temperatureGaugeMinimum: 0
			temperatureGaugeMaximum: 100
			temperatureGaugeStep: 10
		}
		ListElement {
			description: QT_TR_NOOP("Freezer")
			temperatureGaugeMinimum: -30
			temperatureGaugeMaximum: 0
			temperatureGaugeStep: 5
		}
	}

	function temperatureTypeToText(temperatureType) {
		return _validTemperatureType(temperatureType)
				? qsTrId(_temperatureDetails.get(temperatureType).description)
				: //% "Unknown"
				  qsTrId("temperature_type_unknown")
	}

	function temperatureGaugeMinimum(temperatureType) {
		const temp = _validTemperatureType(temperatureType)
				? (_temperatureDetails.get(temperatureType).temperatureGaugeMinimum)
				: (_temperatureDetails.get(VenusOS.Temperature_DeviceType_Generic).temperatureGaugeMinimum)
		return Units.convert(temp, VenusOS.Units_Temperature_Celsius, Global.systemSettings.temperatureUnit)
	}

	function temperatureGaugeMaximum(temperatureType) {
		const temp = _validTemperatureType(temperatureType)
				? (_temperatureDetails.get(temperatureType).temperatureGaugeMaximum)
				: (_temperatureDetails.get(VenusOS.Temperature_DeviceType_Generic).temperatureGaugeMaximum)
		return Units.convert(temp, VenusOS.Units_Temperature_Celsius, Global.systemSettings.temperatureUnit)
	}

	function temperatureGaugeStepSize(temperatureType) {
		return _validTemperatureType(temperatureType)
				? (_temperatureDetails.get(temperatureType).temperatureGaugeStep)
				: (_temperatureDetails.get(VenusOS.Temperature_DeviceType_Generic).temperatureGaugeStep)
	}

	function _validTemperatureType(temperatureType) {
		return (temperatureType >= 0) && (temperatureType < _temperatureDetails.count)
	}

	Component.onCompleted: Global.environmentInputs = root
}
