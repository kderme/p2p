# BitcoinP2P

This project started as an assignment from the IOHK "Haskell and Cryptocurrencies"

summer course held in Athens July-September 2017.

We would in particular like to thank our instructors:

  Lars Brünjes, from IOHK  https://iohk.io/

  Andres Löh, from Well-Typed The Haskell Consultants http://www.well-typed.com/

for motivating, helping us and inspiring us with

their love and passion about haskell.

Of course, we are to blame for any mistakes.

In this project, we implemented a discovery protocol for Nodes in a p2p 

network, where Nodes inform one another for their peers. 

In addition, we implemented a protocol where Nodes exchange their information 

so that they are in synchronization.

We mainly focus on socket programming, concurrency, client-threads and 

robustness of the system, so that it does not collapse when Nodes leave,

but it can continue to exist and adapt after massive Nodes leaving.

