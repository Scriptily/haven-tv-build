# Ambient home screen (Apple TV) - build only

An Apple TV app that shows a self-hosted smart-home dashboard and an ambient screen. This repository only exists so
GitHub Actions can build it: every push builds an unsigned `.ipa` for sideloading (the **Haven-ipa** artifact) and
runs the unit tests.

There is nothing to configure here: the app finds and pairs with its server at runtime.
