/* Cerbo V6 customisation: settings for one detected temperature sensor. */
import QtQuick
import Victron.VenusOS

Page {
	id: root
	required property Device device
	readonly property bool storageReady: Global.environmentInputs.sensorLayoutAvailable

	GradientListView {
		model: VisibleItemModel {
			ListText {
				text: "Device instance"
				secondaryText: String(root.device.deviceInstance)
			}

			ListTextField {
				text: "Display name"
				caption: "This name applies to the custom Environment page, not VRM. Clear to use device name."
				secondaryText: Global.environmentInputs.sensorDisplayName(root.device)
				maximumLength: 40
				writeAccessLevel: VenusOS.User_AccessType_User
				interactive: root.storageReady
				saveInput: function() {
					if (root.storageReady)
						Global.environmentInputs.setSensorName(root.device.deviceInstance, secondaryText)
				}
			}

			ListSwitch {
				text: "Show in Environment"
				checked: Global.environmentInputs.sensorVisible(root.device.deviceInstance)
				interactive: root.storageReady
				writeAccessLevel: VenusOS.User_AccessType_User
				updateDataOnClick: false
				onClicked: Global.environmentInputs.setSensorVisible(root.device.deviceInstance, !checked)
			}

			ListButton {
				text: "Change display order"
				secondaryText: "Move earlier"
				writeAccessLevel: VenusOS.User_AccessType_User
				interactive: root.storageReady
				onClicked: Global.environmentInputs.moveSensor(root.device.deviceInstance, -1)
			}

			ListButton {
				text: "Change display order"
				secondaryText: "Move later"
				writeAccessLevel: VenusOS.User_AccessType_User
				interactive: root.storageReady
				onClicked: Global.environmentInputs.moveSensor(root.device.deviceInstance, 1)
			}
		}
	}
}
