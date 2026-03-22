# PMX_Scripts

## mynatrules.sh quick presentation

This script was made to link **Proxmox** CTs to the Internet and to translate ports from the host to machines using nftables

## How to use it ?

	 chmod +x mynatrules.sh
instructions are pretty clear when you user it. using it without any arguments will display a quick tutorial   	
To avoid having multiple bridges to set up  (the script *should* work fine with multiple bridges) you can englobe multiple networks in a big one  
-> e.g: 192.168.0.1/16 englobes 192.168.X.X/24   
meaning you only need one bridge for 500 CTs using my script   

I advise using it on a 1-99 window starting at X.X.X.100 and wide cidr like /16 because of the following logic  


## The port translation is following this logic

Let's say your proxmox host ip is 172.16.195.5  
Let's say you want to open port 80 on a CT that it's IP is 192.168.4.145  
it will take the 3rd byte of the private IP meaning a window from 1 to 5 inclued and partialy the 6 because of the TCP port limits   


->current port 4  


then it will take the last two digits of the port of the service required if it has more than two  


-> current port 480  


then it will take the last two digits of the CT's IP   

-> current port 48045  		

you'll now be able to acces the ct web page through 172.16.195.5:48045  



