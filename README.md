# psm
Process Smaps Memory view

This programm collects metrics from `/proc/<PID>/smaps_rollup`, then aggregates these numbers.</br>
Aggregation is performed by the binary name from the `/proc/<PID>/exe` link.</br>
The last step is to pretty print the resulting numbers.

# screenshot
![image](https://user-images.githubusercontent.com/2256154/124362049-f1659380-dc5c-11eb-87e5-73e793888fa2.png)
