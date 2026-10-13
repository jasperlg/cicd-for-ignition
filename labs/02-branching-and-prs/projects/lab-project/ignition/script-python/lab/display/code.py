"""lab.display -- formatting helpers for the plant Overview HMI.

Jython 2.7 (Ignition). Pure functions that turn raw tag values into the strings
shown on the screen. No tag or database access here, so you can read and change
this without a gateway — and the lab's validate.sh can parse it offline.
"""

PLACEHOLDER = "--"


def format_reading(value, units):
    """Format a numeric tag reading for an HMI label, e.g. '162.0 °C'.

    Rounds to one decimal place and appends the engineering units. Used by the
    Overview screen's KPI tiles via a runScript binding.
    """
    try:
        return "%.1f %s" % (float(value), units)
    except (TypeError, ValueError):
        return "%s %s" % (PLACEHOLDER, units)
