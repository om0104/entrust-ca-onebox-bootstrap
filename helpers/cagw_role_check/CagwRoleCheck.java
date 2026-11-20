import com.entrust.toolkit.User;
import com.entrust.toolkit.credentials.StreamProfileReader;
import com.entrust.toolkit.util.SecureStringBuffer;
import com.entrust.adminservices.toolkit.AtkContext;
import com.entrust.adminservices.toolkit.AtkContextFactory;
import com.entrust.adminservices.toolkit.AtkObjectFactory;
import com.entrust.adminservices.toolkit.AtkTypeFactory;
import com.entrust.adminservices.toolkit.atkobjects.AtkAdminRoleIntf;
import com.entrust.adminservices.toolkit.atkobjects.AtkPermissionIntf;
import com.entrust.adminservices.toolkit.atkobjects.AtkPermissionListIntf;
import com.entrust.adminservices.toolkit.atkobjects.AtkUserIntf;
import com.entrust.adminservices.toolkit.types.AtkObjectId;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;

/**
 * Read-only check of the CA Gateway admin's ECA role.
 *
 * Logs in with the CAGW admin EPF, reads the admin's own user entry, takes its admin
 * role BY ID, fetches that role by ID, and checks the permissions CAGW needs. It never
 * writes to the CA.
 *
 *   java -cp <this dir>:<CAGW jars> CagwRoleCheck <admin.epf> <xap url> [role id]
 *   EPF password: environment variable CAGW_ADMIN_EPF_PW (never on the command line).
 *   [role id] overrides the admin's own role, for diagnostics only.
 *
 * Exit: 0 = all required permissions granted, 1 = one or more missing, 2 = could not check.
 */
public class CagwRoleCheck {

    // ECA permission name -> ECAA label, and why CAGW needs it.
    private static final String[][] REQUIRED = {
        {"PerformPKIXRequest",  "Users: Perform PKIX requests",
         "without it the CA rejects CAGW's RA-signed CMP (-2207 EntrustProofOfRA ... insufficient permissions, cagw-5502)"},
        {"UserCreateProfile",   "Users: Create user profile",
         "needed to create the enrollee's profile"},
        {"UserAdminRoleModify", "Users: Change user's role",
         "needed when CAGW assigns the enrollee's role"},
        {"UserAuthcodeView",    "Users: View activation codes",
         "without it the CA returns masked codes (****-****-****) and every enrolment fails cagw-5501"},
    };

    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("usage: CagwRoleCheck <admin.epf> <xap url> [role id]   (password in CAGW_ADMIN_EPF_PW)");
            System.exit(2);
        }
        String pw = System.getenv("CAGW_ADMIN_EPF_PW");
        if (pw == null || pw.isEmpty()) {
            System.err.println("CAGW_ADMIN_EPF_PW is not set");
            System.exit(2);
        }
        try {
            System.exit(run(args[0], pw, args[1], args.length > 2 ? args[2] : null));
        } catch (Exception e) {
            System.err.println("CHECK ERROR: " + e);
            System.exit(2);
        }
    }

    private static int run(String epfPath, String pw, String xapUrl, String roleIdOverride) throws Exception {
        User admin = new User();
        admin.login(new StreamProfileReader(new ByteArrayInputStream(Files.readAllBytes(Paths.get(epfPath)))),
                    new SecureStringBuffer(new StringBuffer(pw)));
        String adminDn = admin.getUserDN().getName();

        Map<String, String> props = new HashMap<String, String>();
        props.put("CAVersion", "7");
        props.put("url", xapUrl);
        props.put("min.protocol", "TLSv1.0");
        AtkContext atk = AtkContextFactory.createContext(props, admin);
        atk.connect();
        try {
            String roleId = roleIdOverride;
            if (roleId == null) {
                AtkUserIntf self = (AtkUserIntf) AtkObjectFactory.createObject(atk, AtkUserIntf.OBJECT_NAME);
                self.opGet(AtkTypeFactory.createDN(adminDn));
                roleId = self.getAdminRole().getObjectId().getId();
            }

            AtkAdminRoleIntf role = (AtkAdminRoleIntf) AtkObjectFactory.createObject(atk, AtkAdminRoleIntf.OBJECT_NAME);
            role.setObjectId(new AtkObjectId(roleId));
            role.opGet();

            System.out.println("CAGW admin : " + adminDn);
            System.out.println("Admin role : id=" + roleId + " name=\"" + role.getName() + "\""
                               + (roleIdOverride != null ? "   (role id given on the command line)" : ""));

            AtkPermissionListIntf perms = role.getPermissions().getPermissionList();
            int missing = 0;
            for (String[] r : REQUIRED) {
                AtkPermissionIntf p = perms.getPermission(r[0]);
                boolean granted = p != null && p.isGranted();
                System.out.printf("  %-4s %-30s (%s)%n", granted ? "OK" : "MISS", r[1], r[0]);
                if (!granted) {
                    System.out.println("         -> " + r[2]);
                    missing++;
                }
            }
            if (missing == 0) {
                System.out.println("PASS: role \"" + role.getName() + "\" (id " + roleId + ") has every permission CAGW needs.");
                return 0;
            }
            System.out.println("FAIL: " + missing + " permission(s) missing. In ECAA open Security Policy > Roles > \""
                               + role.getName() + "\", tick the MISS items, commit the security policy,"
                               + " then restart the CA and CAGW.");
            return 1;
        } finally {
            atk.disconnect();
        }
    }
}
