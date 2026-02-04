/*
 * SSLC Parser Library API
 * Header file for libparser.so / parser.dll
 */

#ifndef _PARSER_API_H_
#define _PARSER_API_H_

#ifdef __cplusplus
extern "C" {
#endif

/* Platform-specific calling convention */
#ifdef _WIN32
#define PARSER_API __stdcall
#else
#define PARSER_API
#endif

/* Value types */
enum { V_INT=1, V_FLOAT, V_STRING };

/* Variable location types */
#define V_LOCAL    1
#define V_GLOBAL   2
#define V_IMPORT   3
#define V_EXPORT   4

/* Procedure flags */
#define P_TIMED        0x01
#define P_CONDITIONAL  0x02
#define P_IMPORT       0x04
#define P_EXPORT       0x08
#define P_CRITICAL     0x10
#define P_PURE         0x20
#define P_INLINE       0x40

/* Source reference (line number and file) */
typedef struct {
    int line;
    const char* file;
} Reference;

/* Value union for variables */
typedef struct {
    int type;   /* V_INT, V_FLOAT, or V_STRING */
    union {
        int intData;
        float floatData;
        int stringData;  /* offset into string space */
    };
} Value;

/* Variable information */
typedef struct {
    int name;           /* offset into namelist */
    int* references;
    int numRefs;
    Value value;
    int type;           /* V_LOCAL, V_GLOBAL, V_IMPORT, V_EXPORT */
    int arrayLen;
    int declared;       /* line number where declared */
    const char* fdeclared;  /* file where declared */
    int uses;
    int initialized;
} Variable;

/* Node in the AST */
typedef struct {
    int token;
    const char* file;
    int lineNum;
    Value value;
    int column;
} Node;

typedef struct {
    Node *nodes;
    int numNodes;
} NodeList;

/* Procedure information */
typedef struct {
    int name;           /* offset into namelist */
    int type;           /* P_TIMED, P_CONDITIONAL, etc. */
    union {
        int time;
        NodeList condition;
    };
    char *namelist;     /* procedure's local namelist */
    int numArgs;
    int defined;
    struct {
        Variable *variables;
        int numVariables;
    } variables;
    int* references;
    int numRefs;
    int uses;
    int declared;
    const char* fdeclared;
    int start;
    const char* fstart;
    int end;
    const char* fend;
    NodeList nodes;
    int minArgs;
    int deftype;
    int stringifiedName;
} Procedure;

/*
 * Library API Functions
 */

/**
 * Parse a script file.
 * @param filePath  Path to the preprocessed/temp file to parse
 * @param origPath  Original source file path (for error messages)
 * @param dir       Directory for include file resolution
 * @return 0 on success, non-zero on error
 */
int PARSER_API parse_main(const char *filePath, const char* origPath, const char* dir);

/**
 * Get the number of procedures (excluding the implicit main procedure).
 */
int PARSER_API numProcs(void);

/**
 * Get procedure information by index.
 * @param i     Procedure index (0 to numProcs()-1)
 * @param proc  Output: procedure information
 */
void PARSER_API getProc(int i, Procedure* proc);

/**
 * Get the size of a procedure's local namespace.
 * @param i  Procedure index
 * @return Namespace size in bytes, or -1 if no namespace
 */
int PARSER_API getProcNamespaceSize(int i);

/**
 * Copy a procedure's namespace data.
 * @param i     Procedure index
 * @param data  Output buffer (must be at least getProcNamespaceSize(i) bytes)
 */
void PARSER_API getProcNamespace(int i, char* data);

/**
 * Get the total number of variables (global + external).
 */
int PARSER_API numVars(void);

/**
 * Get variable information by index.
 * @param i    Variable index (0 to numVars()-1)
 * @param var  Output: variable information
 */
void PARSER_API getVar(int i, Variable* var);

/**
 * Get a procedure's local variable.
 * @param i    Procedure index
 * @param j    Local variable index
 * @param var  Output: variable information
 */
void PARSER_API getProcVar(int i, int j, Variable* var);

/**
 * Get the size of the global namespace.
 */
int PARSER_API namespaceSize(void);

/**
 * Copy the global namespace data.
 * @param data  Output buffer (must be at least namespaceSize() bytes)
 */
void PARSER_API getNamespace(char* data);

/**
 * Get the size of the string space.
 */
int PARSER_API stringspaceSize(void);

/**
 * Copy the string space data.
 * @param data  Output buffer (must be at least stringspaceSize() bytes)
 */
void PARSER_API getStringspace(char* data);

/**
 * Get references to a procedure.
 * @param i     Procedure index
 * @param refs  Output: array of references (check Procedure.numRefs for count)
 */
void PARSER_API getProcRefs(int i, Reference* refs);

/**
 * Get references to a variable.
 * @param i     Variable index
 * @param refs  Output: array of references (check Variable.numRefs for count)
 */
void PARSER_API getVarRefs(int i, Reference* refs);

/**
 * Get references to a procedure's local variable.
 * @param i     Procedure index
 * @param j     Local variable index
 * @param refs  Output: array of references
 */
void PARSER_API getProcVarRefs(int i, int j, Reference* refs);

#ifdef __cplusplus
}
#endif

#endif /* _PARSER_API_H_ */
