# lazarus_bis
Gotta collect em all

## Credits
Initial anguish and DSK standalone scripts provided by Dlilah and ... from Verticordious.  
Other lists provided by myself, Dlilah and ...  

## Overview
This script provides a live item tracker for all of your logged in characters.

### Features

- Track who has what items across all currently logged in characters for Anguish, Dreadspire, FUKU, HC Zones, Hand aug, Pre-Anguish, Quest items, Sebilis, Veksar and Vendor items.  
- Shows who needs an item if the item is linked in chat in a comma separated list.  
- Filter what rows are displayed using the search bar. You can search by any item name text in the table such as "infused flux".  
- Show what slots each character has items in. Uncheck the box "Show slots" to hide slot information.  
- Only show items which characters are missing. Check the box "Show Missing Only" to filter out items you already have.  
- Show all characters or only grouped characters. In case you have extra characters logged in like buffers which you don't want to track, you can show only grouped characters from the dropdown menu.  
- Tooltips when hovering over items if the item is showing green because of some other item. For example, if you have crushed an anguish item but you have the Hex aug with that items focus, the item still shows as green.  

### How it works

When you start the script on a character, it will automatically broadcast to the rest of your characters to launch the script in the background.  
It will use `/e3bca` by default as long as you have the `mq2mono` plugin (E3Next users). Otherwise it will use `/dge` from MQ2DanNet.  
Once the script has started, it relies on the new-ish built-in communication feature in MQ to send all your characters item info back to the character which launched the script.
Characters will send updated info when the script starts, whenever you click the `refresh` button or when you switch what list you are viewing.

![](./images/need.png)  
![](./images/sebilis.png)  
![](./images/veksar.png)  
![](./images/dsk.png)  