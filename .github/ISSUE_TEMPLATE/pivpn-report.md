---
name: PiVPN Report 
about: Report issues to PiVPN comunity
title: "Short description of Your Issue here"
labels: 'Needs Investigation'
assignees: ''

---

<!--
# PiVPN Issue Template
PLEASE READ THIS TEMPLATE CAREFULLY BEFORE OPENING AN ISSUE!
Any Issue opened that doesn't follow this template will be removed.


Hi, you are about to open a new issue, Please provide us with all the info required below, incomplete issues will decrease our effectiveness to troubleshoot your issue and increase the time we need to spend helping you out, or with your issue closed even if it is a legitimate issue. Please remember we do not have any super power that makes us guess exactly what your issue is without any decent details!

For any output requested below, you may alternatively post it on https://pastebin.com and provide the Pastebin URL in its place
-->

## In raising this issue, I confirm the following:

`{please fill the checkboxes, e.g: [X]}`

- [] I have read the [documentation](https://docs.pivpn.io)
- [] Is it a feature request? please consider opening a [Discussion] (https://github.com/pivpn/pivpn/discussions/new)
- [] I have read and understood the [contributors guide](https://github.com/pivpn/pivpn/blob/master/CONTRIBUTING.md).
- [] The issue I am reporting can be *replicated*. <!-- READ COMMENT BELOW--> 
- [] The issue I am reporting *is* directly related to the pivpn installer script.<!--READ COMMENT BELOW-->
- [] The issue I am reporting isn't a duplicate (see [FAQs](https://github.com/pivpn/pivpn/wiki/FAQ), [closed issues](https://github.com/pivpn/pivpn/issues?q=is%3Aissue+sort%3Aupdated-desc+is%3Aclosed), and [open issues](https://github.com/pivpn/pivpn/issues?q=is%3Aissue+sort%3Aupdated-desc+is%3Aopen)).

<!--
  Replicated: can you force the issue to happen again?    For example, does it happen again if you run PiVPN on a new and clean system?

  Related to the installer script: can you directly relate to the code? ex: pinpoint a specific function or line of code. 

  feel free not to mark it if you cannot mention the steps to replicate this in another clean system or if you cannot make a direct relation to any of the scripts.
-->

### Has your install failed? 
```
yes/no
```

### Describe the issue
<!-- Please explain your issue. Feel free to format your text -->

**Expected behavior**
A clear and concise description of what you expected to happen.

**Screenshots**
If applicable, add screenshots to help explain your problem.

### Can you replicate the issue? Describe the steps below
<!-- Please explain your issue. Feel free to format your text -->
Steps to reproduce the behavior:
1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

### Have you searched for similar issues and solutions?
    (yes/no / which issues?)


**Additional context**
Add any other context about the problem here.

### Have you taken any steps towards solving your issue?
```
  which?
```

### Please provide your system information
#### What type of hardware are you running PiVPN at?
<!-- Please READ https://docs.pivpn.io/faq/#what-boardsoses-does-pivpn-support -->
```
Raspberrypi (specify the model)
Ordroid
OrangePi
bananaPi
Virtual machine
```
#### Output of `uname -a`
```
  OUTPUT HERE / ANSWER HERE
  DO NOT DELETE THE BACK-TICKS 
  PASTE THE OUTPUT INSIDE THE BACK-TICKS
```

#### Output of `cat /etc/os-release`
```
  OUTPUT HERE / ANSWER HERE
  DO NOT DELETE THE BACK-TICKS 
  PASTE THE OUTPUT INSIDE THE BACK-TICKS
```

### If install failed Please provide the console output of  `curl -L https://install.pivpn.io | bash`
```
  OUTPUT HERE / ANSWER HERE
  DO NOT DELETE THE BACK-TICKS 
  PASTE THE OUTPUT INSIDE THE BACK-TICKS
```

### Console output of      `curl -L install.pivpn.io | bash`
```
  OUTPUT HERE
  DO NOT DELETE THE BACK-TICKS 
  PASTE THE OUTPUT INSIDE THE BACK-TICKS
```
<!-- If the generation of an .ovpn file fails / the ovpns folder stays empty, please paste the output of `pivpn add` or `pivpn add nopass` between the backticks -->

### Console output of      `pivpn add` or `pivpn add nopass`
```
  OUTPUT HERE
  DO NOT DELETE THE BACK-TICKS 
  PASTE THE OUTPUT INSIDE THE BACK-TICKS
```

### Console output of      `pivpn debug`
<!-- Please paste the output of `pivpn debug` between the backticks, don't forget to substitute your public IP address if you don't want the world to know it -->
```
  OUTPUT HERE
  DO NOT DELETE THE BACK-TICKS 
  PASTE THE OUTPUT INSIDE THE BACK-TICKS
```