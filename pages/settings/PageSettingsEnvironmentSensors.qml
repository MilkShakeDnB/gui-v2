/* Cerbo V6 customisation: GX-wide sensor layout settings. */
import QtQuick
import Victron.VenusOS

Page {
	id: root

	GradientListView {
		header: SettingsColumn {
			width: parent?.width ?? 0
			ListInfoLabel {
				text: Global.environmentInputs.sensorLayoutAvailable
					? "Changes are saved on the Cerbo GX for every connected console."
					: "Settings storage is not registered on this Cerbo. Run the V6 settings registration helper before editing."
			}
		}

		model: Global.environmentInputs.allSensors
		delegate: ListNavigation {
			required property Device device
			text: Global.environmentInputs.sensorDisplayName(device)
			secondaryText: "Instance " + device.deviceInstance
				+ (Global.environmentInputs.sensorVisible(device.deviceInstance) ? "" : " · hidden")
			onClicked: Global.pageManager.pushPage("/pages/settings/PageSettingsEnvironmentSensor.qml", {
				device: device,
				title: text,
			})
		}
	}
}
