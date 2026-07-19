# ``MaritimeRouteDiagnostic``

## Overview

A diagnostic message generated during route calculation.

A ``MaritimeRouteDiagnostic`` provides warnings or errors about the generated route, such as shallow waters, restricted areas, or adverse weather conditions.

> Note: Diagnostics with an error severity mean the route should not be navigated.

## Topics

### Properties
- ``kind``
- ``severity``
- ``message``
- ``affectedLegIndex``
