# Security Policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's **Security** tab and
choose **Report a vulnerability**. Please don't open a public issue for them.

Include what you found, the steps to reproduce it, and which version of the scripts you ran. You will
get a reply within a week.

## Scope

The scripts run on your own PC as your Windows user. They read your World of Warcraft `WTF` folder
and write only to the `!ForeverRestore` addon folder and `%LOCALAPPDATA%\ForeverSavedVars`. The
installer registers one scheduled task for your user. The scripts make no network connections.
