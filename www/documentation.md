# Hue Scenes

Control4 driver for activating and deactivating Philips Hue scenes via the Hue Bridge CLIP v2 API. Supports both regular scenes and smart scenes.

### Setup

1. Find your Hue Bridge IP address
2. Generate a Hue Bridge application key
3. Get the scene ID from the Hue API
4. Enter all three values in the driver properties

### Driver Properties

- **Bridge IP** - The IP address of your Hue Bridge
- **Hue Bridge App Key** - Your Hue API application key
- **Scene ID** - The UUID of the scene to control
- **Is A Smart Scene** - Set to "Yes" if the scene is a Hue smart scene
- **Debug Mode** - Enable for detailed logging (auto-disables after 8 hours)

### Actions

- **Recall Scene** - Activate the configured Hue scene
- **Scene Off** - Deactivate the configured Hue scene

### Connections

- **On Button Link** (300) - Bind to a keypad button for scene on
- **Off Button Link** (301) - Bind to a keypad button for scene off
- **Toggle Button Link** (302) - Bind to a keypad button for scene toggle

### Release Notes

- Version 1: Initial release
- Version 2: Bug fixes and cleanup
- Version 3: Full rewrite - extracted common HTTP logic, fixed smart scene toggle bug, removed hardcoded defaults, cleaned up code structure
