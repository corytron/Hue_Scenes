# Hue Scenes - Control4 Driver

Control4 DriverWorks driver for activating and deactivating Philips Hue scenes via the Hue Bridge CLIP v2 API. Supports both regular scenes and smart scenes.

The driver presents itself as a simple on/off light switch in the Control4 UI, mapping ON to scene recall and OFF to scene deactivation.

## Prerequisites

- Philips Hue Bridge (v2 / square model) with API access
- A Hue Bridge application key ([how to generate one](https://developers.meethue.com/develop/hue-api-v2/getting-started/))
- The scene ID you want to control (found via the Hue API or Hue app)

## Hue Bridge Setup

1. Find your Hue Bridge IP address (check your router or use the Hue app under Settings > My Hue system > Hue Bridge).
2. Generate an application key by following the [Hue developer getting started guide](https://developers.meethue.com/develop/hue-api-v2/getting-started/).
3. Get your scene ID by querying the bridge API:
   ```
   GET https://<bridge-ip>/clip/v2/resource/scene
   ```
   Use your app key in the `hue-application-key` header. Find the scene you want and copy its `id` field.

   For smart scenes, query:
   ```
   GET https://<bridge-ip>/clip/v2/resource/smart_scene
   ```

## Composer Setup

1. Add the Hue Scenes driver to your project.
2. In the driver properties, configure:
   - **Bridge IP** - Your Hue Bridge IP address
   - **Hue Bridge App Key** - The application key generated above
   - **Scene ID** - The UUID of the Hue scene to control
   - **Is A Smart Scene** - Set to "Yes" if the scene is a Hue smart scene
3. The driver will appear under **Lights** in room navigators as an on/off switch.
4. To use button links, bind the On/Off/Toggle connections to keypads or other button devices in Composer.
5. Use the **Recall Scene** and **Scene Off** actions in Composer programming for automation.

## How It Works

- **Recall Scene (ON)** - Sends a PUT request to the Hue CLIP v2 API to activate the scene.
- **Scene Off (OFF)** - For regular scenes, recalls the scene at brightness 0. For smart scenes, sends a deactivate command.
- **Toggle** - Switches between on and off based on the current tracked state.

The driver exposes three button link connections (On, Off, Toggle) for keypad integration, and reports its on/off state back to the Control4 light proxy.

## Debug Mode

Enable Debug Mode in the driver properties to see detailed logging in the Lua output window. Debug mode automatically turns off after 8 hours.

## Release Notes

- Version 1: Initial release
- Version 2: Bug fixes and cleanup
- Version 3: Full rewrite - extracted common HTTP logic, fixed smart scene toggle bug, removed hardcoded defaults, cleaned up code structure
