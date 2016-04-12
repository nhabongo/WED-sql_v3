--CREATE LANGUAGE plpython3u;
--CREATE ROLE wed_admin WITH superuser noinherit;
--GRANT wed_admin TO wedflow;

--SET ROLE wed_admin;
--Insert (or modify) a new WED-atribute in the apropriate tables 
------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wed_attr_handler() RETURNS TRIGGER AS 
$wah$
    
    if TD['event'] == 'INSERT':
        #--plpy.notice('Inserting new attribute: ' + TD['new']['name'])
        query = 'CREATE TABLE %s (wid integer primary key, %s text default %s, \
                 FOREIGN KEY (wid) REFERENCES ST_STATUS (wid) ON DELETE RESTRICT)' % \
                (plpy.quote_ident(TD['new']['aname']),plpy.quote_ident(TD['new']['aname']),
                (plpy.quote_literal(TD['new']['adv']) if TD['new']['adv'] else 'NULL'))
        try:
            plpy.execute(query)
        except plpy.SPIError as e:
            plpy.error('Could not create new WED-attribute %s' % (TD['new']['aname']), e)
        
        #--plpy.info('WED-attribute "'+TD['new']['aname']+'" inserted into wed_flow')
        return 'OK'
            
    elif TD['event'] == 'UPDATE':
        for k in TD['old'].keys():
            if (TD['new'][k] != TD['old'][k]) and (k != 'enabled'):
                plpy.error('You can only disable an WED-attribute. Use SP attribute_toggle(aid)')
        if TD['new']['enabled'] == TD['old']['enabled']:
            plpy.error('WED-attribute already enabled/disabled')
        
        return 'OK'            
       
        
    #-- An attribute column can only be dropped if there aren't any pending transactions for all wed-states and it is not
    #--'referenced' by any predicate (cpred column in wed_trig table), otherwise an error should be raised.
    elif TD['event'] == 'DELETE':
        plpy.error('You can only disable an WED-attribute. Use SP ...')
        #--TODO: check if it is okay to remove the requested wed-attribute
            
    else:
        plpy.error('UNDEFINED EVENT')
       
$wah$ LANGUAGE plpython3u SECURITY DEFINER;

CREATE OR REPLACE FUNCTION update_wedflow_view() RETURNS TRIGGER AS
$uw$
    plpy.info('updating view "wed_flow" ...')
    try:
        wed_attr = plpy.execute('select aname from wed_attr where enabled order by aname')
        plpy.execute('SET client_min_messages = error; drop view if exists wed_flow')
    except plpy.SPIError as e:
        plpy.error('Could not update "wed_flow" view : %s' % (e))
    al = len(wed_attr)

    if al == 0:
        return None
    elif al == 1:
        try:
            plpy.execute('create view wed_flow as select * from '+wed_attr[0]['aname'])
        except plpy.SPIError as e:
            plpy.error(e)
    else:
        base_query = 'create view wed_flow as select * from '+wed_attr[0]['aname']+' full join '\
                     +wed_attr[1]['aname']+' using(wid)'
        for a in wed_attr[2:]:
            base_query += ' full join '+a['aname']+' using(wid)'
        try:
            plpy.execute(base_query)
        except plpy.SPIError as e:
            plpy.error(e)
    try:
        plpy.execute('create trigger kernel_trigger instead of insert or update or delete on wed_flow \
                      for each row execute procedure kernel_function()')
        plpy.execute('SET client_min_messages = notice')
    except plpy.SPIError as e:
            plpy.error(e)

$uw$ LANGUAGE plpython3u SECURITY DEFINER;

DROP TRIGGER IF EXISTS wed_attr_trg_a ON wed_attr;
DROP TRIGGER IF EXISTS wed_attr_trg_b ON wed_attr;
CREATE TRIGGER wed_attr_trg_a
BEFORE INSERT OR UPDATE OR DELETE ON wed_attr
    FOR EACH ROW EXECUTE PROCEDURE wed_attr_handler();
CREATE TRIGGER wed_attr_trg_b
AFTER INSERT OR UPDATE OR DELETE ON wed_attr
    FOR EACH ROW EXECUTE PROCEDURE update_wedflow_view();

--Insert a WED-flow modification into WED-trace (history)
------------------------------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION kernel_function() RETURNS TRIGGER AS $kt$
    
    from os import urandom
    from datetime import datetime
    import hashlib
    import json
    from plpy import spiexceptions
    
    #--Generates new instance trigger token ----------------------------------------------------------------------------
    def new_uptkn(trigger_name):
        salt = urandom(5)
        hash = hashlib.md5(salt + trigger_name)
        return hash.hexdigest()

    #--Match predicates against the new state -------------------------------------------------------------------------
    def pred_match():
        
        trmatched = []
        try:
            res_wed_trig = plpy.execute('select * from wed_trig where enabled')
        except plpy.SPIError:
            plpy.error('wed_trig scan error')
        else:
            for tr in res_wed_trig:
                try:
                    res_wed_flow = plpy.execute('select * from wed_flow where wid='+str(TD['new']['wid'])+' and ('+tr['cpred']+')')
                except plpy.SPIError as e:
                    plpy.error('PREDICATE MATCH ERROR!: Invalid predicate (cpred) in WED_trig table')
                else:
                    if res_wed_flow:
                        trmatched.append((tr['trname'],tr['tgid'],tr['timeout']))
        return trmatched
   
    def json_wed_state():
        
        payload = TD['new'].copy()
        del payload['wid']
        
        return json.dumps(payload)
        
    def is_final(trmatched):
        return '_FINAL' in [x[0] for x in trmatched if x[0] == '_FINAL']
        
    #--Fire WED-triggers given a WED-condtions set  --------------------------------------------------------------------
    def squeeze_all_triggers(trmatched):
        
        trfired = []
        
        if is_final(trmatched):
            return trfired
        
        wid = TD['new']['wid']
        payload = json_wed_state()
        
        #--plan = plpy.prepare('insert into job_pool (wid,tgid,trname,timeout,payload) values ($1,$2,$3,$4,$5)',['integer','integer','text','interval','json'])
        
        for trname,tgid,timeout in trmatched:
            try:
                plpy.execute('insert into job_pool (wid,tgid,trname,timeout,payload) values (%d,%d,%s,$s::interval,$s::json)' %\
                             (wid,tgid,trname,timeout,payload))
            except spiexceptions.UniqueViolation:
                #--plpy.info('UNIQUE VIOLAtioN: JOB_POOL')
                pass
            except plpy.SPIError as e:
                plpy.error(e)
            else:
                trfired.append(trname)
                msg = {'wid':wid,'tgid':tgid, 'timeout':timeout, 'payload':payload}
                try:
                    plpy.execute('NOTIFY '+trname+', \''+json.dumps(msg)+'\'')
                except plpy.SPIError as e:
                    plpy.notice('Notification error:',e)
                    
        return trfired
                
    #--Create a new entry on history (WED_trace table) -----------------------------------------------------------------
    def new_trace_entry(trw=None,trf=None,status='R'):
     
        payload = json_wed_state()
        
        plan = plpy.prepare('INSERT INTO wed_trace (wid,trw,trf,status,state) VALUES ($1,$2,$3,$4,$5)',['integer','text','text[]','text','json'])
        try:
            plpy.execute(plan, [TD['new']['wid'],trw,trf,status,payload])
        except plpy.SPIError as e:
            plpy.info('Could not insert new entry into wed_trace')
            plpy.error(e)
    
    #-- Create a new entry on ST_STATUS for fast detecting final states ------------------------------------------------
    def new_st_status_entry():
        try:
            plpy.execute('INSERT INTO st_status (wid) VALUES (' +str(TD['new']['wid'])+ ')')
        except plpy.SPIError as e:
            plpy.info('Could not insert new entry into st_status')
            plpy.error(e)    
    
    
    #-- Find job with uptkn on JOB_POOL (locked and inside timout window)-----------------------------------------------
    def find_job(pid):
        try:
            res = plpy.execute('select oid from pg_database where datname = current_database()')
        except plpy.SPIError as e:
            plpy.error(e)
        
        dbid = res[0]['oid']
        
        try:
            res = plpy.execute('select classid,objid from pg_locks where locktype=\'advisory\' and granted and database='+str(dbid)+' and pid='+str(pid))
        except plpy.SPIError as e:
            plpy.error(e)
        
        if not res:
            return None
        
        wid,tgid = res[0]['classid'], res[0]['objid']
        
        try:
            res = plpy.execute('select trname from job_pool where wid='+str(wid)+' and tgid='+str(tgid))
        except plpy.SPIError as e:
            plpy.error(e)
        
        if not res:
            return None
                
        return (wid,tgid,res[0]['trname'])
        
    def remove_job(wid,tgid):
        try:
            plpy.execute('delete from job_pool where wid='+str(wid)+' and tgid='+str(tgid))
        except plpy.SPIError as e:
            plpy.error(e)
                   
    #-- scan job_pool for pending transitions for WED-flow instance wid
    def check_for_pending_jobs():
        try:
            res = plpy.execute('select wid from job_pool where wid='+str(TD['new']['wid']))
        except plpy.SPIError:
            plpy.error('ERROR: job_pool scanning')
        
        return True if len(res) > 0 else False
        
    
    #-- Check if a given wed-flow instance is already on a final state -------------------------------------------------
    def get_st_status():
        try:
            res = plpy.execute('select status from st_status where wid='+str(TD['new']['wid']))
        except plpy.SPIError:
            plpy.error('Reading st_status')
        else:
            if not len(res):
                plpy.error('wid not found !')
            else:
                return res[0]['status']
    
    #-- Set an WED-state status (final or not final)
    def set_st_status(status='R'):
        try:
            res = plpy.execute('update st_status set status=\''+status+'\' where wid='+str(TD['new']['wid'])+
                               ' and not exists(select 1 from st_status where wid='+str(TD['new']['wid'])+' and \
                               status=\''+status+'\')')
        except plpy.SPIError:
            plpy.error('Status set error on st_status table')

    def get_worker_pid():
        try:
            res = plpy.execute('select pg_backend_pid() as pid')
        except plpy.SPIError:
            plpy.error('Error: identifying worker !')
        
        return res[0]['pid']
        
    def terminate_worker(pid):
        try:
            res = plpy.execute('select pg_terminate_backend('+str(pid)+')')
        except plpy.SPIError:
            plpy.error('Error: terminating worker (pid:'+str(pid)+')')
        
        plpy.info(res)
        
        
    #--(START) TRIGGER CODE --------------------------------------------------------------------------------------------

               
    
    #-- New wed-flow instance (AFTER INSERT)----------------------------------------------------------------------------
    if TD['event'] in ['INSERT']:
        #--First insert WED-attribute values in their respective tables ------------------------------------------------
        try:
            res = plpy.execute('select nextval(\'widseq\')')
        except plpy.SPIError as e:
            plpy.error(e)
        wid = res[0]['nextval']
        TD['new']['wid'] = wid
        new_st_status_entry()
        for attr in TD['new'].keys():
            if attr != 'wid':
                try:
                    plpy.execute('insert into '+attr+' values ('+str(wid)+','+('\''+TD['new'][attr]+'\'' if TD['new'][attr] else 'DEFAULT')+')')
                except plpy.SPIError as e:
                    plpy.error(e)
        #---------------------------------------------------------------------------------------------------------------
        
        #--Then start WED-SQL main algorithm----------------------------------------------------------------------------
        trmatched = pred_match()
        
        if (not trmatched):
            plpy.error('No predicate matches this initial WED-state, aborting ...')
        
        if is_final(trmatched):
            status = 'F'
        else:
            status = 'R'
        
        trfired = squeeze_all_triggers(trmatched)
        new_trace_entry('_INIT',trfired,status)
        set_st_status(status)
        
        return "OK"
        
            

    #-- Updating an WED-state ------------------------------------------------------------------------------------------
    elif TD['event'] in ['UPDATE']:
        
        #--First update each WED-attribute table -----------------------------------------------------------------------
        if TD['old']['wid'] != TD['new']['wid']:
            plpy.error('Cannot change WED-flow id !')
        for attr in TD['new'].keys():
            if attr != 'wid':
                if TD['new'][attr] != TD['old'][attr]:
                    try:
                        plpy.execute('update '+attr+' set '+attr+'=\''+TD['new'][attr]+'\' where wid='+str(TD['old']['wid']))
                    except plpy.SPIError as e:
                        plpy.error(e)
        #---------------------------------------------------------------------------------------------------------------

        #--Then start WED-SQL main algorithm----------------------------------------------------------------------------
        
        status = get_st_status()
        
        if status == 'F':
            plpy.error('Cannot modify a final WED-state !')
        
        #-- check if the transaction is the same that set the advisory lock (transaction still open)
        pid = get_worker_pid()
        job =  find_job(pid)
        
        if not job:
            plpy.error('Job not found !')
        
        if job[0] != TD['new']['wid']:
            plpy.error('Invalid update !')
        
        #--validations and match
        trmatched = pred_match()
        plpy.info(trmatched)
        remove_job(job[0],job[1])

        trfired = squeeze_all_triggers(trmatched)
        
        final = is_final(trmatched)
        pj = check_for_pending_jobs()
        
        
        if final and pj:
            plpy.error('Impossible to set a final WED-state if there are others pending WED-transactions for this instance')
        elif not (trfired or pj or final):
            plpy.info('Inconsistent WED-state detected')
            status = 'E'
            #--lanch an exception job
            squeeze_all_triggers([('_EXCPT',job[1],'01:00:00')])
        else:
            status = 'F' if final else 'R'
        
        new_trace_entry(job[2],trfired,status)
        set_st_status(status)
        
        return "OK"
        
       
    #--(END) TRIGGER CODE ----------------------------------------------------------------------------------------------    
$kt$ LANGUAGE plpython3u SECURITY DEFINER;

--DROP TRIGGER IF EXISTS kernel_trigger ON wed_flow;
--CREATE TRIGGER kernel_trigger
--AFTER INSERT OR UPDATE ON wed_flow
--    FOR EACH ROW EXECUTE PROCEDURE kernel_function();
    

------------------------------------------------------------------------------------------------------------------------
-- Validate predicate (cpred) and final condition on WED_trig table
CREATE OR REPLACE FUNCTION wed_trig_validation_bfe() RETURNS TRIGGER AS $wtv$
    
    if TD['event'] in ['INSERT','UPDATE']:       
        import re
            
        fbdtkn = re.compile(r'CREATE|DROP|ALTER|GRANT|REVOKE|SELECT|INSERT|UPDATE|DELETE|;',re.I)        
        found = fbdtkn.search(TD['new']['cpred'])
        if found:
            plpy.error('Forbidden character or SQL keyword found in cpred expression: '+ found.group(0))
            #--return "SKIP"
        
        if TD['new']['trname']:
            trname = re.compile(r'^_')
            sysname = trname.search(TD['new']['trname'])
            if sysname:
                plpy.error('trname must not start with an underscore character !')
                #--return "SKIP"
        
        if TD['new']['cfinal']:
            TD['new']['trname'] = TD['new']['tgname'] = TD['new']['cname'] = '_FINAL'
            TD['new']['timeout'] = None
            return "MODIFY"
        else:
            return "OK"  
    
$wtv$ LANGUAGE plpython3u SECURITY DEFINER;

DROP TRIGGER IF EXISTS wed_trig_trg_bfe ON wed_trig;
CREATE TRIGGER wed_trig_trg_bfe
BEFORE INSERT OR UPDATE ON wed_trig
    FOR EACH ROW EXECUTE PROCEDURE wed_trig_validation_bfe();

--RESET ROLE;


