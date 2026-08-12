"""ptrsetup — copy a live World of Warcraft UI onto the PTR client.

The package splits cleanly in two:

* ``detect`` / ``fsops`` / ``configwtf`` — pure filesystem logic, no web layer,
  fully unit-testable against a fake install tree.
* ``steps`` / ``app`` — the guide, expressed as data, and the local web wizard
  that renders it.
"""

__version__ = "0.1.0"
