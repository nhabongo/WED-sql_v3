from BaseWorker import BaseClass
import sys,time

class MyWorker(BaseClass):
    
    #trname and dbs variables are static in order to conform with the definition of wed_trans()    
    trname = 'tr_a3'
    dbs = 'user=lt5 dbname=lt5 application_name=ww-tr_a3'
    wakeup_interval = 5
    
    def __init__(self):
        super().__init__(MyWorker.trname,MyWorker.dbs,MyWorker.wakeup_interval)
        
    def wed_trans(self,payload):
        time.sleep(5)
        print (payload)
        return "a3=(a3::integer + 1)::text"
        
w = MyWorker()

try:
    w.run()
except KeyboardInterrupt:
    print()
    sys.exit(0)

