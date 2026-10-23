# Nord location switching

Choose a NordVPN location and establish a native IKEv2 connection while retaining access to the user's Tailscale network.

## Language

**Location**:
A NordVPN country or city the user can choose as the destination of their VPN connection.
_Avoid_: Server, profile

**Server**:
A specific NordVPN endpoint offering IKEv2 service in a location. Several servers may serve the same location.
_Avoid_: Location, country

**Catalogue**:
The available countries and cities offered for selection. It does not contain account credentials.
_Avoid_: Full server inventory

**Connection**:
The user's active or attempted NordVPN IKEv2 session. A selected location is not evidence that its connection has succeeded.
_Avoid_: Selected location

**Tailscale access**:
The user's ability to reach their private Tailscale devices and services.
_Avoid_: Nord connection, ordinary internet access

**Service credentials**:
The NordVPN username and password used for manual VPN connections, distinct from the user's Nord account sign-in.
_Avoid_: Nord account password, access token
