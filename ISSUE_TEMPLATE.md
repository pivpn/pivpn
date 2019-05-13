<!-- 
# PiVPN Issue Template
PLEASE READ THIS TEMPLATE CAREFULLY BEFORE OPENING AN ISSUE! 
Any Issue opened that doesn't follow this template will be removed. 


Hi, you are about to open a new issue, Please provide us with all the info required below, incomplete issues will decrease our effectiveness to troubleshoot your issue and increase the time we need to spend helping you out, or with your issue closed even if it is a legitimate issue. Please remember we do not have any super power that makes us guess exactly what your issue is without any decent details!

For any output requested below, you may alternatively post it on http://pastebin.com and provide the Pastebin URL in its place
-->

## In raising this issue, I confirm the following: 

`{please fill the checkboxes, e.g: [X]}`

- [] I have read and understood the [contributors guide](https://github.com/pivpn/pivpn/blob/master/CONTRIBUTING.md).
- [] The issue I am reporting can be *replicated*.
- [] The issue I am reporting can be *is* directly related to the pivpn installer script.
- [] The issue I am reporting isn't a duplicate (see [FAQs](https://github.com/pivpn/pivpn/wiki/FAQ), [closed issues](https://github.com/pivpn/pivpn/issues?q=is%3Aissue+sort%3Aupdated-desc+is%3Aclosed), and [open issues](https://github.com/pivpn/pivpn/issues?q=is%3Aissue+sort%3Aupdated-desc+is%3Aopen)).




<!-- If the install failed: can you please copy-paste the console output after running `curl install.pivpn.io | bash` between the backticks -->

<!-- Please explain your issue. Feel free to format your text -->
### Issue


### Have you searched for similar issues and solutions?
    (yes/no / which issues?)


### Console output of      `curl -L install.pivpn.io | bash`
```
  Output Here
```
<!-- If the generation of an .ovpn file fails / the ovpns folder stays empty, please paste the output of `pivpn add` or `pivpn add nopass` between the backticks -->

### Console output of      `pivpn add` or `pivpn add nopass`
```
  Output Here
```
<!-- Please paste the output of `pivpn debug` between the backticks, don't forget to substitute your public IP address if you don't want the world to know it -->
### Console output of      `pivpn debug`
```
  Output Here
```

### Console Output of      `sudo iptables -t nat -S`
```
  Output Here
```

### Console Output of      `sudo iptables -S`
```
  Output Here
```

### Console Output of      `sudo netstat -uanp | grep openvpn`

```
  Output Here
```

### Have you taken any steps towards solving your issue?
```
  which?
```