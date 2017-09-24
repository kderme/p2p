# BitcoinP2P

This project started as an assignment from the IOHK "Haskell and Cryptocurrencies" <br />
summer course held in Athens July-September 2017. <br />

We would in particular like to thank our instructors: <br />

 - Lars Brünjes, from IOHK  https://iohk.io/ <br />
 - Andres Löh, from Well-Typed The Haskell Consultants http://www.well-typed.com/ 

for motivating, helping us and inspiring us with their love and passion about haskell. <br />

Of course, we are to blame for any mistakes. <br />
<br />

## About
In this project, we implemented a discovery protocol for Nodes in a p2p  <br />
network, where Nodes inform one another about their peers. <br />
In addition, we implemented a protocol where Nodes exchange their information <br />
so that they are in synchronization. <br />
<br />

## Target
We mainly focus on socket programming, concurrency, client-threads and <br />
robustness of the system, so that it does not collapse when Nodes leave. <br />
It can continue to exist and adapt even after many Nodes have left. <br />

