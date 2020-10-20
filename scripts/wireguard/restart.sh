#!/bin/bash


if systemctl restart wg-quick@wg0; then
    echo "::: WireGuard restarted"
else
    echo "::: Failed to restart WireGuard"
fi