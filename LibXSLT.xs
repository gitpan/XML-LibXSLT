/* $Id: LibXSLT.xs 191 2006-11-17 18:27:58Z pajas $ */

#ifdef __cplusplus
extern "C" {
#endif
#include <libxslt/xsltconfig.h>
#include <libxslt/xslt.h>
#include <libxslt/xsltInternals.h>
#include <libxslt/transform.h>
#include <libxslt/xsltutils.h>
#include <libxslt/imports.h>
#include <libxslt/extensions.h>
#include <libxslt/security.h>
#ifdef HAVE_EXSLT
#include <libexslt/exslt.h>
#include <libexslt/exsltconfig.h>
#endif
#include <libxml/xmlmemory.h>
#include <libxml/HTMLtree.h>
#include <libxml/xmlIO.h>
#include <libxml/tree.h>
#include <libxml/parser.h>
#include <libxml/parserInternals.h>
#include <libxml/xpathInternals.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "perl-libxml-mm.h"
#include "ppport.h"
#ifdef __cplusplus
}
#endif

#define SET_CB(cb, fld) \
    RETVAL = cb ? newSVsv(cb) : &PL_sv_undef;\
    if (SvOK(fld)) {\
        if (cb) {\
            if (cb != fld) {\
                sv_setsv(cb, fld);\
            }\
        }\
        else {\
            cb = newSVsv(fld);\
        }\
    }\
    else {\
        if (cb) {\
            SvREFCNT_dec(cb);\
            cb = NULL;\
        }\
    }

#define SET_CB2(cb, fld) cb=fld;

static SV * LibXSLT_debug_cb = NULL;
static HV * LibXSLT_HV_allCallbacks = NULL;

void
LibXSLT_free_all_callbacks(void)
{
    if (LibXSLT_debug_cb) {
        SvREFCNT_dec(LibXSLT_debug_cb);
        LibXSLT_debug_cb = NULL;
    }
}

int
LibXSLT_iowrite_scalar(void * context, const char * buffer, int len)
{
    SV * scalar;
    
    scalar = (SV *)context;

    sv_catpvn(scalar, (const char*)buffer, len);
    
    return len;
}

int
LibXSLT_ioclose_scalar(void * context)
{
    return 0;
}

int
LibXSLT_iowrite_fh(void * context, const char * buffer, int len)
{
    dSP;
    
    SV * ioref;
    SV * tbuff;
    SV * results;
    int cnt;
    
    ENTER;
    SAVETMPS;
    
    ioref = (SV *)context;
    
    tbuff = newSVpvn((char*)buffer, len);

    PUSHMARK(SP);
    EXTEND(SP, 2);
    PUSHs(ioref);
    PUSHs(sv_2mortal(tbuff));
    PUTBACK;
    
    cnt = call_method("print", G_SCALAR | G_EVAL);
    
    SPAGAIN;
    
    if (cnt != 1) {
        croak("fh->print() method call failed");
    }
    
    results = POPs;
    
    if (!SvOK(results)) {
        croak("print to fh failed");
    }
    
    PUTBACK;
    
    FREETMPS;
    LEAVE;
    
    return len;
}

int
LibXSLT_ioclose_fh(void * context)
{
    return 0; /* we let Perl close the FH */
}

void
LibXSLT_error_handler_ctx(void * ctxt, const char * msg, ...)
{
	va_list args;
	SV * saved_error = (SV *) ctxt;

	/* If saved_error is null we croak with the error */
	if( saved_error == NULL ) {
		SV * sv = sv_2mortal(newSV(0));
		va_start(args, msg);
   		sv_vsetpvfn(sv, msg, strlen(msg), &args, NULL, 0, NULL);
   		va_end(args);
		croak("%s", SvPV_nolen(sv));
	/* Otherwise, save the error */
	} else {
		va_start(args, msg);
   		sv_vcatpvfn(saved_error, msg, strlen(msg), &args, NULL, 0, NULL);
		va_end(args);
	}
}

static void
LibXSLT_init_error_ctx(SV * saved_error)
{
  xmlSetGenericErrorFunc((void *) saved_error, (xmlGenericErrorFunc) LibXSLT_error_handler_ctx);
  xsltSetGenericErrorFunc((void *) saved_error, (xmlGenericErrorFunc) LibXSLT_error_handler_ctx);
}

static void
LibXSLT_report_error_ctx(SV * saved_error, int warn_only)
{
    if( 0 < SvCUR( saved_error ) ) {
      if ( warn_only ) {
	warn("%s", SvPV_nolen(saved_error));
      } else {
	croak("%s", SvPV_nolen(saved_error));
      }
    }
}

void
LibXSLT_debug_handler(void * ctxt, const char * msg, ...)
{
    dSP;
    
    va_list args;
    SV * sv;
    
    sv = NEWSV(0,512);

    va_start(args, msg);
    sv_vsetpvfn(sv, msg, strlen(msg), &args, NULL, 0, NULL);
    va_end(args);

    if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
        int cnt = 0;
    
        ENTER;
        SAVETMPS;
        
        PUSHMARK(SP);
        EXTEND(SP, 1);
        PUSHs(sv);
        PUTBACK;

        cnt = call_sv(LibXSLT_debug_cb, G_SCALAR | G_EVAL);

        SPAGAIN;

        if (cnt != 1) {
            croak("debug handler call failed");
        }

        PUTBACK;

        FREETMPS;
        LEAVE;
    }
    
    SvREFCNT_dec(sv);
}

static void
LibXSLT_generic_function (xmlXPathParserContextPtr ctxt, int nargs) {
    xmlXPathObjectPtr obj,ret;
    xmlNodeSetPtr nodelist = NULL;
    int count;
    SV * perl_dispatch;
    int i;
    STRLEN len;
    SV * perl_result;
    ProxyNodePtr owner = NULL;
    char * tmp_string;
    STRLEN n_a;
    double tmp_double;
    int tmp_int;
    AV * array_result;
    xmlNodePtr tmp_node, tmp_node1;
    SV *key;
    char *strkey;
    const char *function, *uri;
    SV **perl_function;
    AV *arguments;
    dSP;
    
    function = (const char *) ctxt->context->function;
    uri = (const char *) ctxt->context->functionURI;
    
    key = newSVpvn("",0);
    sv_catpv(key, "{");
    sv_catpv(key, (const char*)uri);
    sv_catpv(key, "}");
    sv_catpv(key, (const char*)function);
    strkey = SvPV(key, len);
    perl_function = hv_fetch(LibXSLT_HV_allCallbacks, strkey, len, 0);
    SvREFCNT_dec(key);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    
    XPUSHs(*perl_function);

    /* set up call to perl dispatcher function */
    for (i = 0; i < nargs; i++) {
        obj = (xmlXPathObjectPtr)valuePop(ctxt);
        switch (obj->type) {
        case XPATH_NODESET:
        case XPATH_XSLT_TREE:
            nodelist = obj->nodesetval;
            if ( nodelist ) {
                XPUSHs(sv_2mortal(newSVpv("XML::LibXML::NodeList", 0)));				
                XPUSHs(sv_2mortal(newSViv(nodelist->nodeNr)));
                if ( nodelist->nodeNr > 0 ) {
                    int i = 0 ;
                    const char * cls = "XML::LibXML::Node";
                    xmlNodePtr tnode;
                    SV * element;
                    len = nodelist->nodeNr;
                    for( ; i < len; i++ ){
                        tnode = nodelist->nodeTab[i];
                        /*
                        if( tnode != NULL	&& tnode->doc != NULL) {
                            owner = SvPROXYNODE(sv_2mortal(x_PmmNodeToSv((xmlNodePtr)(tnode->doc), NULL)));
                        }
                        */
                        if (tnode->type == XML_NAMESPACE_DECL) {
                            element = sv_newmortal();
                            cls = x_PmmNodeTypeName( tnode );
                            element = sv_setref_pv( element,
                                                    (const char *)cls,
                                                    (void *)xmlCopyNamespace((xmlNsPtr)tnode)
                                                );
                        }
                        else {
                            /* need to copy the node as libxml2 will free it */
                            xmlNodePtr tnode_cpy = xmlCopyNode(tnode, 1);
                            element = x_PmmNodeToSv(tnode_cpy, owner);
                        }
                        XPUSHs( sv_2mortal(element) );
                    }
                }
            }
            break;
        case XPATH_BOOLEAN:
            XPUSHs(sv_2mortal(newSVpv("XML::LibXML::Boolean", 0)));
            XPUSHs(sv_2mortal(newSViv(obj->boolval)));
            break;
        case XPATH_NUMBER:
            XPUSHs(sv_2mortal(newSVpv("XML::LibXML::Number", 0)));
            XPUSHs(sv_2mortal(newSVnv(obj->floatval)));
            break;
        case XPATH_STRING:
            XPUSHs(sv_2mortal(newSVpv("XML::LibXML::Literal", 0)));
            XPUSHs(sv_2mortal(newSVpv((char*)obj->stringval, 0)));
            break;
        default:
            /* warn("Unknown XPath return type (%d) in call to {%s}%s - assuming string", obj->type, uri, function); */
            XPUSHs(sv_2mortal(newSVpv("XML::LibXML::Literal", 0)));
            XPUSHs(sv_2mortal(newSVpv((char*)xmlXPathCastToString(obj), 0)));
        }
        xmlXPathFreeObject(obj);
    }

    /* call perl dispatcher */
    PUTBACK;

    perl_dispatch = sv_2mortal(newSVpv("XML::LibXSLT::perl_dispatcher",0));
    count = call_sv(perl_dispatch, G_SCALAR|G_EVAL);
    
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        POPs;
        croak("LibXSLT: error coming back from perl-dispatcher in pm file. %s\n", SvPV(ERRSV, n_a));
    } 

    if (count != 1) croak("LibXSLT: perl-dispatcher in pm file returned more than one argument!\n");
    
    perl_result = POPs;

    if (!SvOK(perl_result)) {
        ret = (xmlXPathObjectPtr)xmlXPathNewCString("");		
        goto FINISH;
    }

    /* convert perl result structures to LibXML structures */
    if (sv_isobject(perl_result) && 
        (SvTYPE(SvRV(perl_result)) == SVt_PVMG ||
         SvTYPE(SvRV(perl_result)) == SVt_PVAV))
    {
        if (sv_derived_from(perl_result, "XML::LibXML::NodeList")) {
            ret = xmlXPathNewNodeSet(NULL);
            ret->boolval = 1; /* free children */
            array_result = (AV*)SvRV(perl_result);
            while (av_len(array_result) >= 0) {
                tmp_node1 = (xmlNodePtr)x_PmmSvNode(sv_2mortal(av_shift(array_result)));
                tmp_node = xmlDocCopyNode(tmp_node1, ctxt->context->doc, 1);
                xmlXPathNodeSetAdd(ret->nodesetval, tmp_node);
                /*
                 * this seems unnecessary with recent libxslt versions
                 *
		    if (ret->user == NULL) {
		      ret->user = (void*)tmp_node;
		    }
		 *
                 * this even causes segmentation faults:
                 *
                   else {
                      xmlNodePtr old = (xmlNodePtr)(ret->user);
                      old->prev = tmp_node;
                      tmp_node->next = old;
                      ret->user = (void*)tmp_node;
		    }
                */
            }
            goto FINISH;
        } 
        else if (sv_derived_from(perl_result, "XML::LibXML::Node")) {
            ret =  (xmlXPathObjectPtr)xmlXPathNewNodeSet(NULL);
            ret->boolval = 1; /* free children */
            tmp_node1 = (xmlNodePtr)x_PmmSvNode(perl_result);
            tmp_node = xmlDocCopyNode(tmp_node1, ctxt->context->doc, 1);
            xmlXPathNodeSetAdd(ret->nodesetval,tmp_node);
            /*
             * this seems unnecessary with recent libxslt versions
             *
                ret->user = (void*)tmp_node; 
            */
            goto FINISH;
        }
        else if (sv_derived_from(perl_result, "XML::LibXML::Boolean")) {
            tmp_int = SvIV(SvRV(perl_result));
            ret = (xmlXPathObjectPtr)xmlXPathNewBoolean(tmp_int);
            goto FINISH;
        }
        else if (sv_derived_from(perl_result, "XML::LibXML::Literal")) {
            tmp_string = SvPV(SvRV(perl_result), len);
            ret = (xmlXPathObjectPtr)xmlXPathNewCString(tmp_string);
            goto FINISH;
        }
        else if (sv_derived_from(perl_result, "XML::LibXML::Number")) {
            tmp_double = SvNV(SvRV(perl_result));
            ret = (xmlXPathObjectPtr)xmlXPathNewFloat(tmp_double);
            goto FINISH;
        }
    }
    ret = (xmlXPathObjectPtr)xmlXPathNewCString(SvPV(perl_result, len));

FINISH:

    valuePush(ctxt, ret);
    PUTBACK;
    FREETMPS;
    LEAVE;	
}

int
LibXSLT_input_match(char const * filename)
{
    int results;
    int count;
    SV * res;

    results = 0;

    {
        dTHX;
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        EXTEND(SP, 1);
        PUSHs(sv_2mortal(newSVpv((char*)filename, 0)));
        PUTBACK;

        count = call_pv("XML::LibXML::InputCallback::_callback_match", 
                             G_SCALAR | G_EVAL);

        SPAGAIN;

        if (count != 1) {
            croak("match callback must return a single value");
        }

        if (SvTRUE(ERRSV)) {
            POPs ;
            croak("input match callback died: %s", SvPV_nolen(ERRSV));
        }

        res = POPs;

        if (SvTRUE(res)) {
            results = 1;
        }

        PUTBACK;
        FREETMPS;
        LEAVE;
    }
    return results;
}

void *
LibXSLT_input_open(char const * filename)
{
    SV * results;
    int count;

    dTHX;
    dSP;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    EXTEND(SP, 1);
    PUSHs(sv_2mortal(newSVpv((char*)filename, 0)));
    PUTBACK;

    count = call_pv("XML::LibXML::InputCallback::_callback_open", 
                              G_SCALAR | G_EVAL);

    SPAGAIN;

    if (count != 1) {
        croak("open callback must return a single value");
    }

    if (SvTRUE(ERRSV)) {
        POPs ;
        croak("input callback died: %s", SvPV_nolen(ERRSV));
    }

    results = POPs;

    SvREFCNT_inc(results);

    PUTBACK;
    FREETMPS;
    LEAVE;

    return (void *)results;
}

int
LibXSLT_input_read(void * context, char * buffer, int len)
{
    STRLEN res_len;
    const char * output;
    SV * ctxt;

    res_len = 0;
    ctxt = (SV *)context;

    {
        int count;

        dTHX;
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        EXTEND(SP, 2);
        PUSHs(ctxt);
        PUSHs(sv_2mortal(newSViv(len)));
        PUTBACK;

        count = call_pv("XML::LibXML::InputCallback::_callback_read", 
                             G_SCALAR | G_EVAL);

        SPAGAIN;

        if (count != 1) {
            croak("read callback must return a single value");
        }

        if (SvTRUE(ERRSV)) {
            POPs ;
            croak("read callback died: %s", SvPV_nolen(ERRSV));
        }

        output = POPp;
        if (output != NULL) {
            res_len = strlen(output);
            if (res_len) {
                strncpy(buffer, output, res_len);
            }
            else {
                buffer[0] = 0;
            }
        }

	PUTBACK;
        FREETMPS;
        LEAVE;
    }
    return res_len;
}

void
LibXSLT_input_close(void * context)
{
    SV * ctxt;

    ctxt = (SV *)context;

    {
        dTHX;
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        EXTEND(SP, 1);
        PUSHs(ctxt);
        PUTBACK;

        call_pv("XML::LibXML::InputCallback::_callback_close", 
                             G_SCALAR | G_EVAL | G_DISCARD);

        SvREFCNT_dec(ctxt);

        if (SvTRUE(ERRSV)) {
            croak("close callback died: %s", SvPV_nolen(ERRSV));
        }

        FREETMPS;
        LEAVE;
    }
}

int
LibXSLT_security_check(xsltSecurityOption option,
                       xsltSecurityPrefsPtr sec,
                       xsltTransformContextPtr ctxt,
                       const char * value)
{
   int result = 0;

   {
      int count;

      dTHX;
      dSP;

      ENTER;
      SAVETMPS;

      PUSHMARK(SP);
      EXTEND(SP, 3);
      PUSHs(sv_2mortal(newSViv(option)));
      PUSHs(sv_setref_pv(sv_newmortal(), "XML::LibXSLT::TransformContext",
                         (void*)ctxt));
      PUSHs(sv_2mortal(newSVpv((char*)value, 0)));
      PUTBACK;

      count = call_pv("XML::LibXSLT::Security::_security_check",
                      G_SCALAR | G_EVAL);

      SPAGAIN;

      if (count != 1) {
         croak("security callbacks must return a single value");
      }

      if (SvTRUE(ERRSV)) {
         POPs;
         croak("security callback died: %s", SvPV_nolen(ERRSV));
      }

      result = POPi;

      PUTBACK;
      FREETMPS;
      LEAVE;
   }

   return result;
}

int
LibXSLT_security_read_file(xsltSecurityPrefsPtr sec,
                           xsltTransformContextPtr ctxt,
                           const char * value)
{
   return LibXSLT_security_check(XSLT_SECPREF_READ_FILE, sec, ctxt, value);
}

int
LibXSLT_security_write_file(xsltSecurityPrefsPtr sec,
                           xsltTransformContextPtr ctxt,
                           const char * value)
{
   return LibXSLT_security_check(XSLT_SECPREF_WRITE_FILE, sec, ctxt, value);
}

int
LibXSLT_security_create_dir(xsltSecurityPrefsPtr sec,
                            xsltTransformContextPtr ctxt,
                            const char * value)
{
   return LibXSLT_security_check(XSLT_SECPREF_CREATE_DIRECTORY, sec, ctxt, value);
}

int
LibXSLT_security_read_net(xsltSecurityPrefsPtr sec,
                          xsltTransformContextPtr ctxt,
                          const char * value)
{
   return LibXSLT_security_check(XSLT_SECPREF_READ_NETWORK, sec, ctxt, value);
}

int
LibXSLT_security_write_net(xsltSecurityPrefsPtr sec,
                           xsltTransformContextPtr ctxt,
                           const char * value)
{
   return LibXSLT_security_check(XSLT_SECPREF_WRITE_NETWORK, sec, ctxt, value);
}

xsltSecurityPrefsPtr
LibXSLT_init_security_prefs(xsltTransformContextPtr ctxt)
{
   xsltSecurityPrefsPtr sec = NULL;
   sec = xsltNewSecurityPrefs();

   xsltSetSecurityPrefs(sec, XSLT_SECPREF_READ_FILE,
                        LibXSLT_security_read_file);
   xsltSetSecurityPrefs(sec, XSLT_SECPREF_WRITE_FILE,
                        LibXSLT_security_write_file);
   xsltSetSecurityPrefs(sec, XSLT_SECPREF_CREATE_DIRECTORY,
                        LibXSLT_security_create_dir);
   xsltSetSecurityPrefs(sec, XSLT_SECPREF_READ_NETWORK,
                        LibXSLT_security_read_net);
   xsltSetSecurityPrefs(sec, XSLT_SECPREF_WRITE_NETWORK,
                        LibXSLT_security_write_net);

   xsltSetCtxtSecurityPrefs(sec, ctxt);

   return sec;
}

void
LibXSLT_free_security_prefs(xsltSecurityPrefsPtr sec,
                            xsltTransformContextPtr ctxt)
{
   xsltFreeSecurityPrefs(sec);
}


MODULE = XML::LibXSLT         PACKAGE = XML::LibXSLT

PROTOTYPES: DISABLE

BOOT:
    LIBXML_TEST_VERSION
    if (xsltLibxsltVersion < LIBXSLT_VERSION) {
      warn("Warning: XML::LibXSLT compiled against libxslt %d, "
           "but runtime libxslt is older %d\n", LIBXSLT_VERSION, xsltLibxsltVersion);
    }
    xsltMaxDepth = 250;
    xsltSetXIncludeDefault(1);
    LibXSLT_HV_allCallbacks = newHV();
#ifdef HAVE_EXSLT
    exsltRegisterAll();
#endif

char *
LIBXSLT_DOTTED_VERSION()
    CODE:
        RETVAL = LIBXSLT_DOTTED_VERSION;
    OUTPUT:
        RETVAL


int
LIBXSLT_VERSION()
    CODE:
        RETVAL = LIBXSLT_VERSION;
    OUTPUT:
        RETVAL

int
LIBXSLT_RUNTIME_VERSION()
    CODE:
        RETVAL = xsltLibxsltVersion;
    OUTPUT:
        RETVAL

int
xinclude_default(self, ...)
        SV * self
    CODE:
        RETVAL = xsltGetXIncludeDefault();
        if (items > 1) {
           xsltSetXIncludeDefault(SvIV(ST(1)));
        }
    OUTPUT:
        RETVAL

int
max_depth(self, ...)
        SV * self
    CODE:
        RETVAL = xsltMaxDepth;
        if (items > 1) {
            xsltMaxDepth = SvIV(ST(1));
        }
    OUTPUT:
        RETVAL

void
register_function(self, uri, name, callback)
        SV * self
        char * uri
        char * name
        SV *callback
    PPCODE:
    {
        SV *key;
        STRLEN len;
        char *strkey;
        
        /* todo: Add checking of uri and name in here! */
        xsltRegisterExtModuleFunction((const xmlChar *)name,
                        (const xmlChar *)uri,
                        LibXSLT_generic_function);
        key = newSVpvn("",0);
        sv_catpv(key, "{");
        sv_catpv(key, (const char*)uri);
        sv_catpv(key, "}");
        sv_catpv(key, (const char*)name);
        strkey = SvPV(key, len);
        /* warn("Trying to store function '%s' in %d\n", strkey, LibXSLT_HV_allCallbacks); */
        hv_store(LibXSLT_HV_allCallbacks, strkey, len, SvREFCNT_inc(callback), 0);
        SvREFCNT_dec(key);
    }

SV *
debug_callback(self, ...)
        SV * self
    CODE:
        if (items > 1) {
            SV * debug_cb = ST(1);
            if (debug_cb && SvTRUE(debug_cb)) {
                SET_CB(LibXSLT_debug_cb, ST(1));
            }
            else {
                LibXSLT_debug_cb = NULL;
            }
        }
        RETVAL = LibXSLT_debug_cb ? sv_2mortal(LibXSLT_debug_cb) : &PL_sv_undef;
    OUTPUT:
        RETVAL

xsltStylesheetPtr
_parse_stylesheet(self, sv_doc)
        SV * self
        SV * sv_doc
    PREINIT:
        char * CLASS = "XML::LibXSLT::Stylesheet";
        xmlDocPtr doc_copy;
        xmlDocPtr doc;
        SV * saved_error = sv_2mortal(newSVpv("",0));
    CODE:
        if (sv_doc == NULL) {
            XSRETURN_UNDEF;
        }
        doc = (xmlDocPtr)x_PmmSvNode( sv_doc );
        if (doc == NULL) {
            XSRETURN_UNDEF;
        }
        doc_copy = xmlCopyDoc(doc, 1);
        if (doc_copy->URL == NULL) {
          doc_copy->URL = xmlStrdup(doc->URL);
        }
        /* xmlNodeSetBase((xmlNodePtr)doc_copy, doc_copy->URL); */

        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }

        LibXSLT_init_error_ctx(saved_error);
        RETVAL = xsltParseStylesheetDoc(doc_copy);
        if (RETVAL == NULL) {
            xmlFreeDoc(doc_copy);
	    LibXSLT_report_error_ctx(saved_error,0);
            XSRETURN_UNDEF;
        }
	LibXSLT_report_error_ctx(saved_error,1);
    OUTPUT:
        RETVAL

xsltStylesheetPtr
_parse_stylesheet_file(self, filename)
        SV * self
        const char * filename
    PREINIT:
        char * CLASS = "XML::LibXSLT::Stylesheet";
        SV * saved_error = sv_2mortal(newSVpv("",0));
    CODE:

        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }

        LibXSLT_init_error_ctx(saved_error);
        RETVAL = xsltParseStylesheetFile((const xmlChar *)filename);
        if (RETVAL == NULL) {
            LibXSLT_report_error_ctx(saved_error,0);
            XSRETURN_UNDEF;
        }
        LibXSLT_report_error_ctx(saved_error,1);
    OUTPUT:
        RETVAL

void
lib_init_callbacks( self )
        SV * self
    CODE:
        xmlRegisterInputCallbacks((xmlInputMatchCallback) LibXSLT_input_match,
                                  (xmlInputOpenCallback) LibXSLT_input_open,
                                  (xmlInputReadCallback) LibXSLT_input_read,
                                  (xmlInputCloseCallback) LibXSLT_input_close);

void
lib_cleanup_callbacks( self )
        SV * self
    CODE:
        xmlCleanupInputCallbacks();
        xmlRegisterDefaultInputCallbacks();

MODULE = XML::LibXSLT         PACKAGE = XML::LibXSLT::Stylesheet

PROTOTYPES: DISABLE

SV *
transform(self, wrapper, sv_doc, ...)
        xsltStylesheetPtr self
        SV * wrapper
        SV * sv_doc
    PREINIT:
        # note really only 254 entries here - last one is NULL
        const char *xslt_params[255];
        xmlDocPtr real_dom;
        xmlDocPtr doc;
        SV * saved_error = sv_2mortal(newSVpv("",0));
        xsltTransformContextPtr ctxt;
        xsltSecurityPrefsPtr sec;
    CODE:
        if (sv_doc == NULL) {
            XSRETURN_UNDEF;
        }
        doc = (xmlDocPtr)x_PmmSvNode( sv_doc );
        if (doc == NULL) {
            XSRETURN_UNDEF;
        }
        xslt_params[0] = 0;
        if (items > 256) {
            croak("Too many parameters in transform()");
        }
        if ((items - 3) % 2) {
            croak("Odd number of parameters");
        }
        if (items > 3) {
            int i;
            for (i = 3; (i < items && i < 256); i++) {
                xslt_params[i - 3] = (char *)SvPV(ST(i), PL_na);
            }
            # set last entry to NULL
            xslt_params[i - 3] = 0;
        }

        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }

        LibXSLT_init_error_ctx(saved_error);

        /* we need own context to distinguish
         * <xsl:message terminate="no">
         * from those with terminate="yes" and fatal errors */
	ctxt = xsltNewTransformContext(self, doc);
        if (ctxt == NULL) {
	    croak("Could not create transformation context");
	}
        ctxt->xinclude = 1;
        ctxt->_private = (void *) wrapper;
        sec = LibXSLT_init_security_prefs(ctxt);
	real_dom = xsltApplyStylesheetUser(self, doc, xslt_params,
					   NULL, NULL, ctxt);
        if ((real_dom != NULL) && (ctxt->state != XSLT_STATE_OK)) {
          /* fatal error */
             xmlFreeDoc(real_dom);
             real_dom = NULL;
	}
        LibXSLT_free_security_prefs(sec, ctxt);
	xsltFreeTransformContext(ctxt);

        /* real_dom = xsltApplyStylesheet(self, doc, xslt_params); */
        if (real_dom == NULL) {
            if ( real_dom != NULL ) xmlFreeDoc( real_dom );
            LibXSLT_report_error_ctx(saved_error,0);
            croak("Unknown error applying stylesheet");
        }
        if (real_dom->type == XML_HTML_DOCUMENT_NODE) {
            if (self->method != NULL) {
                xmlFree(self->method);
            }
            self->method = (xmlChar *) xmlMalloc(5);
            strcpy((char *) self->method, "html");
        }
        /* non-fatal: probably just a message from the stylesheet */
        LibXSLT_report_error_ctx(saved_error,1);
        RETVAL = x_PmmNodeToSv((xmlNodePtr)real_dom, NULL);
    OUTPUT:
        RETVAL

SV *
transform_file(self, wrapper, filename, ...)
        xsltStylesheetPtr self
        SV * wrapper
        char * filename
    PREINIT:
        # note really only 254 entries here - last one is NULL
        const char *xslt_params[255];
        xmlDocPtr real_dom;
        xmlDocPtr source_dom;
        SV * saved_error = sv_2mortal(newSVpv("",0));
        xsltTransformContextPtr ctxt;
        xsltSecurityPrefsPtr sec;
    CODE:
        xslt_params[0] = 0;
        if (items > 256) {
            croak("Too many parameters in transform()");
        }
        if ((items - 3) % 2) {
            croak("Odd number of parameters");
        }
        if (items > 3) {
            int i;
            for (i = 3; (i < items && i < 256); i++) {
                xslt_params[i - 3] = (char *)SvPV(ST(i), PL_na);
            }
            # set last entry to NULL
            xslt_params[i - 3] = 0;
        }
        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }
        LibXSLT_init_error_ctx(saved_error);
        source_dom = xmlParseFile(filename);
        if ( source_dom == NULL ) {
            LibXSLT_report_error_ctx(saved_error,0);
            croak("Unknown error loading source document");
        } else {
	  /*real_dom = xsltApplyStylesheet(self, source_dom, xslt_params);*/

	   ctxt = xsltNewTransformContext(self, source_dom);
	   if (ctxt == NULL) {
	     croak("Could not create transformation context");
	   }
	   ctxt->xinclude = 1;
           ctxt->_private = (void *) wrapper;
           sec = LibXSLT_init_security_prefs(ctxt);
	   real_dom = xsltApplyStylesheetUser(self, source_dom, xslt_params,
					      NULL, NULL, ctxt);
	   if ((ctxt->state != XSLT_STATE_OK) && real_dom) {
               /* fatal error */
               xmlFreeDoc(real_dom);
               real_dom = NULL;
           }
           LibXSLT_free_security_prefs(sec, ctxt);
	   xsltFreeTransformContext(ctxt);

	   xmlFreeDoc( source_dom );
        }
        
        if (real_dom == NULL) {
            LibXSLT_report_error_ctx(saved_error,0);
            croak("Unknown error applying stylesheet");
        }
        /* non-fatal: probably just a message from the stylesheet */
        LibXSLT_report_error_ctx(saved_error,1);
        if (real_dom->type == XML_HTML_DOCUMENT_NODE) {
            if (self->method != NULL) {
                xmlFree(self->method);
            }
            self->method = xmlStrdup((const xmlChar *) "html");
        }
        RETVAL = x_PmmNodeToSv((xmlNodePtr)real_dom, NULL);
    OUTPUT:
        RETVAL

void
DESTROY(self)
        xsltStylesheetPtr self
    CODE:
        if (self == NULL) {
            XSRETURN_UNDEF;
        }
        xsltFreeStylesheet(self);

SV *
_output_string(self, sv_doc, bytes_vs_chars=0)
        xsltStylesheetPtr self
        SV * sv_doc
        int bytes_vs_chars
    PREINIT:
        xmlOutputBufferPtr output;
        SV * results = newSVpv("", 0);
        const xmlChar *encoding = NULL;
        xmlCharEncodingHandlerPtr encoder = NULL;
        xmlDocPtr doc = (xmlDocPtr)x_PmmSvNode( sv_doc );
    CODE:
        XSLT_GET_IMPORT_PTR(encoding, self, encoding)
        if (encoding != NULL) {
            encoder = xmlFindCharEncodingHandler((char *)encoding);
        if ((encoder != NULL) &&
                 (xmlStrEqual((const xmlChar *)encoder->name,
                              (const xmlChar *) "UTF-8")))
                encoder = NULL;
        }

        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }
        output = xmlOutputBufferCreateIO( 
            (xmlOutputWriteCallback) LibXSLT_iowrite_scalar,
            (xmlOutputCloseCallback) LibXSLT_ioclose_scalar,
            (void*)results,
            (bytes_vs_chars == 2) ? NULL : encoder
	    );
        if (xsltSaveResultTo(output, doc, self) == -1) {
            croak("output to scalar failed");
        }
        xmlOutputBufferClose(output);

        if ((bytes_vs_chars == 2) ||
            (bytes_vs_chars == 0) && xmlStrEqual(encoding, (const xmlChar *) "UTF-8")) {
	  SvUTF8_on( results );
	}
        RETVAL = results;
    OUTPUT:
        RETVAL

void
output_fh(self, sv_doc, fh)
        xsltStylesheetPtr self
        SV * sv_doc
        SV * fh
    PREINIT:
        xmlOutputBufferPtr output;
        const xmlChar *encoding = NULL;
        xmlCharEncodingHandlerPtr encoder = NULL;
        xmlDocPtr doc = (xmlDocPtr)x_PmmSvNode( sv_doc );
    CODE:
        XSLT_GET_IMPORT_PTR(encoding, self, encoding)
        if (encoding != NULL) {
            encoder = xmlFindCharEncodingHandler((char *)encoding);
        if ((encoder != NULL) &&
                 (xmlStrEqual((const xmlChar *)encoder->name,
                              (const xmlChar *) "UTF-8")))
                encoder = NULL;
        }

        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }
        output = xmlOutputBufferCreateIO( 
            (xmlOutputWriteCallback) LibXSLT_iowrite_fh,
            (xmlOutputCloseCallback) LibXSLT_ioclose_fh,
            (void*)fh,
            encoder
            );
        if (xsltSaveResultTo(output, doc, self) == -1) {
            croak("output to fh failed");
        }
        xmlOutputBufferClose(output);
        
void
output_file(self, sv_doc, filename)
        xsltStylesheetPtr self
        SV * sv_doc
        char * filename
    PREINIT:
        xmlDocPtr doc = (xmlDocPtr)x_PmmSvNode( sv_doc );
    CODE:
        if (LibXSLT_debug_cb && SvTRUE(LibXSLT_debug_cb)) {
            xsltSetGenericDebugFunc(PerlIO_stderr(), (xmlGenericErrorFunc)LibXSLT_debug_handler);
        }
        else {
            xsltSetGenericDebugFunc(NULL, NULL);
        }
        xsltSaveResultToFilename(filename, doc, self, 0);

char *
media_type(self)
        xsltStylesheetPtr self
    PREINIT:
    	xmlChar *mediaType;
    	xmlChar *method;
    CODE:
    	XSLT_GET_IMPORT_PTR(mediaType, self, mediaType);
	
	if(mediaType == NULL) {
    	    XSLT_GET_IMPORT_PTR(method, self, method);
            RETVAL = "text/xml";
            /* this below is rather simplistic, but should work for most cases */
            if (method != NULL) {
        	if (strcmp(method, "html") == 0) {
                    RETVAL = "text/html";
        	}
        	else if (strcmp(method, "text") == 0) {
                    RETVAL = "text/plain";
        	}
            }
        }
	else {
	    RETVAL = mediaType;
	}
    OUTPUT:
        RETVAL

char *
output_encoding(self)
        xsltStylesheetPtr self
    PREINIT:
    	xmlChar *encoding;
    CODE:
    	XSLT_GET_IMPORT_PTR(encoding, self, encoding)
	
        RETVAL = encoding;
        if (RETVAL == NULL) {
            RETVAL = "UTF-8";
        }
    OUTPUT:
        RETVAL


MODULE = XML::LibXSLT         PACKAGE = XML::LibXSLT::TransformContext

SV *
stylesheet(self)
      xsltTransformContextPtr self
   CODE:
      RETVAL = SvREFCNT_inc((SV *) self->_private);
   OUTPUT:
      RETVAL
